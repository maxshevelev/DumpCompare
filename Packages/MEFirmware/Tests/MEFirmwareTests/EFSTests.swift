import XCTest
import Foundation
@testable import MEFirmware

/// Phase 9 (newer FS) — EFS paged-volume + FITC "OEM Configuration" structural
/// decode. Synthetic fixtures reproduce the on-flash layout upstream walks
/// (efs_anl MEA.py 8621 / fitc_anl 8572): an EFS System page whose header,
/// index area and Data Page header/footer CRCs are filled by an *independent*
/// bitwise IV-0 CRC (not the table-driven `CRC32.crc32IV0Raw` under test), so a
/// shared wrong implementation cannot fake a "valid". The two real-byte CRC
/// vectors live in ChecksumTests. Facts asserted here mirror the CSME 15.0.30
/// dump (1.bin: EFS @0x267000 1 System + 14 Data + 1 Scratch page, dict 0x0A;
/// FITC @0x1F2000 revision 1) plus negative cases. Tests never touch the network.
final class EFSTests: XCTestCase {

    // MARK: Fixtures

    private static let pageSize = 0x1000
    private static let pageHeaderSize = 0x10
    private static let indexPaddingLength = 0x08

    /// Independent bitwise reflected CRC-32 from register IV 0, no final XOR —
    /// the same *result* as `CRC32.crc32IV0Raw` but computed bit-by-bit so the
    /// fixture builder does not depend on the implementation under test.
    private static func crcIV0Raw(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
        }
        return crc
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private static func le32(_ v: UInt32) -> Data {
        var out = Data()
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8((v >> UInt32(shift)) & 0xFF))
        }
        return out
    }

    /// A System Page: header (dictionary `dict`, Revision/Unknown1 1/2) then one
    /// current index area `[order bytes][8 zero padding][CRC]`, the rest 0xFF.
    private static func systemPage(dictionary: UInt16 = 0x000A,
                                   committed: UInt8 = 2, reserved: UInt8 = 0,
                                   order: [UInt8]) -> Data {
        var page = Data(repeating: 0xFF, count: pageSize)
        // Header: Unknown0 0x0001, Dictionary, Revision 1, Unknown1 2, Com, Res,
        // DictRevision 1, CRC over [0x00:0x0C].
        page.replaceSubrange(0..<2, with: le16(0x0001))
        page.replaceSubrange(2..<4, with: le16(dictionary))
        page.replaceSubrange(4..<8, with: le32(1))
        page[8] = 2
        page[9] = committed
        page[10] = reserved
        page[11] = 1
        page.replaceSubrange(12..<16, with: le32(crcIV0Raw(page[0..<12])))

        // Index area right after the header: order + zero padding + CRC.
        var indexArea = Data(order)
        indexArea.append(Data(repeating: 0x00, count: indexPaddingLength))
        let crc = crcIV0Raw(indexArea)
        indexArea.append(le32(crc))
        page.replaceSubrange(pageHeaderSize..<(pageHeaderSize + indexArea.count),
                             with: indexArea)
        return page
    }

    /// A Data Page (dictionary 0x0000, non-erased Unknown0). `reserved` fills
    /// the body with 0xFF and the footer CRC with 0xFFFFFFFF so the parser skips
    /// its footer check (upstream dat_ftr_crc32_skip); otherwise the body is a
    /// marker pattern and the footer CRC validates it.
    private static func dataPage(seed: UInt8, reserved: Bool = false) -> Data {
        var page = Data(repeating: 0xFF, count: pageSize)
        page.replaceSubrange(0..<2, with: le16(0x0000))   // Unknown0 ≠ 0xFFFF ⇒ Data
        page.replaceSubrange(2..<4, with: le16(0x0000))   // Dictionary 0x0000 (Data)
        page.replaceSubrange(4..<8, with: le32(1))        // Revision (unused for Data)
        page[8] = 0                                       // Unknown1 (unused for Data)
        page[9] = 0
        page[10] = 0
        page[11] = 0
        page.replaceSubrange(12..<16, with: le32(crcIV0Raw(page[0..<12])))

        if !reserved {
            for i in 0..<(pageSize - pageHeaderSize - 4) {
                page[pageHeaderSize + i] = UInt8(truncatingIfNeeded: Int(seed) &+ i)
            }
        }
        page.replaceSubrange((pageSize - 8)..<(pageSize - 4),
                             with: le32(0xFFFF_FFFF))       // Footer Unknown
        let body = page[pageHeaderSize..<(pageSize - 4)]
        let footerCRC: UInt32 = reserved ? 0xFFFF_FFFF : crcIV0Raw(body)
        page.replaceSubrange((pageSize - 4)..<pageSize, with: le32(footerCRC))
        return page
    }

    /// Default 3-page volume: System page + 2 Data pages. Index order [1, 0]
    /// proves the parser reads the permutation, not physical page order.
    private static func makeVolume() -> Data {
        var out = systemPage(committed: 2, reserved: 0, order: [1, 0])
        out.append(dataPage(seed: 0x00))
        out.append(dataPage(seed: 0x40))
        return out
    }

    // MARK: EFS decode

    func testParsesSystemVolumeFacts() throws {
        let region = Self.makeVolume()
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0x1000,
                                                mfsDictionary: 0x0A))
        XCTAssertEqual(vol.offset, 0x1000)
        XCTAssertEqual(vol.pageSize, 0x1000)
        XCTAssertEqual(vol.systemPageCount, 1)
        XCTAssertEqual(vol.dataPageCount, 2)
        XCTAssertEqual(vol.scratchPageCount, 0)
        XCTAssertTrue(vol.scratchPagesEmpty)
        XCTAssertTrue(vol.dataPageCountMatchesSystem)
        XCTAssertEqual(vol.dictionary, 0x000A)
        XCTAssertEqual(vol.revision, 1)
        XCTAssertEqual(vol.unknown1, 2)
        XCTAssertEqual(vol.dataPagesCommitted, 2)
        XCTAssertEqual(vol.dataPagesReserved, 0)
        XCTAssertEqual(vol.dictionaryRevision, 1)
        XCTAssertTrue(vol.systemHeaderCRCValid)
        XCTAssertTrue(vol.indexesCRCValid)
        XCTAssertTrue(vol.firstIndexPaddingEmpty)
        XCTAssertEqual(vol.dataPageOrder, [1, 0])
        XCTAssertTrue(vol.dataPageHeaderCRCsValid)
        XCTAssertTrue(vol.dataPageFooterCRCsValid)
        XCTAssertEqual(vol.matchesMFSDictionary, true)
    }

    func testMatchesMFSDictionaryNilWhenNoMFS() throws {
        let region = Self.makeVolume()
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertNil(vol.matchesMFSDictionary)
    }

    func testMatchesMFSDictionaryFalseOnMismatch() throws {
        let region = Self.makeVolume()
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: 0x0B))
        XCTAssertEqual(vol.matchesMFSDictionary, false)
    }

    func testScratchPagesMustBeAllFF() throws {
        var region = Self.makeVolume()
        // Append a page whose header classifies it as Scratch (dictionary
        // 0xFFFF, Unknown0 0xFFFF) but that carries one dirty byte.
        var scratch = Data(repeating: 0xFF, count: Self.pageSize)
        scratch[0x123] = 0xAB
        region.append(scratch)
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertEqual(vol.scratchPageCount, 1)
        XCTAssertFalse(vol.scratchPagesEmpty)
    }

    func testDataPageReservedSkipsFooterCheck() throws {
        var region = Self.systemPage(committed: 2, reserved: 0, order: [0, 1])
        region.append(Self.dataPage(seed: 0x10))
        region.append(Self.dataPage(seed: 0x00, reserved: true))  // reserved body
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertTrue(vol.dataPageHeaderCRCsValid)
        XCTAssertTrue(vol.dataPageFooterCRCsValid)   // reserved footer skipped
    }

    func testCorruptedHeaderCRCReportedNotThrown() throws {
        var region = Self.makeVolume()
        region[0x0C] ^= 0xFF                          // flip a byte of stored CRC
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertFalse(vol.systemHeaderCRCValid)
        XCTAssertTrue(vol.indexesCRCValid)            // rest still decodes
    }

    func testCorruptedDataPageHeaderCRCReported() throws {
        var region = Self.makeVolume()
        region[Self.pageSize + 0x0C] ^= 0xFF          // page 1 header CRC byte
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertFalse(vol.dataPageHeaderCRCsValid)
    }

    func testDirtyFirstIndexPaddingReported() throws {
        var region = Self.makeVolume()
        // Padding sits at header end + sysDataCount (2 index bytes): byte 0x12.
        // The assertion is on the padding fact alone; the index CRC is left
        // mismatching by the same dirty byte, which is not asserted here.
        region[Self.pageHeaderSize + 2] = 0x01
        let vol = try XCTUnwrap(EFSParser.parse(in: region, offset: 0,
                                                size: region.count,
                                                absoluteOffset: 0, mfsDictionary: nil))
        XCTAssertFalse(vol.firstIndexPaddingEmpty)
    }

    func testNonSystemLeadingPageReturnsNil() {
        // A Data-looking first page is not an EFS volume.
        let region = Self.dataPage(seed: 0x00)
        XCTAssertNil(EFSParser.parse(in: region, offset: 0, size: region.count,
                                     absoluteOffset: 0, mfsDictionary: nil))
    }

    func testScratchLeadingPageReturnsNil() {
        let region = Data(repeating: 0xFF, count: Self.pageSize)
        XCTAssertNil(EFSParser.parse(in: region, offset: 0, size: region.count,
                                     absoluteOffset: 0, mfsDictionary: nil))
    }

    // MARK: FITC decode

    /// A revision-1 FITC header + payload. `mangle` flips a byte of the stored
    /// HeaderChecksum ([4:8]) after the CRCs are computed — the header CRC span
    /// zeroes that field, so only the stored value changes and the revision
    /// stays 1, failing the header check independently of the data checks.
    private static func makeFITC(_ mangle: Bool = false) -> Data {
        let payload = Data((0..<0x80).map { UInt8(($0 * 7 + 3) & 0xFF) })
        var header = Data(repeating: 0x00, count: 0x10)
        header.replaceSubrange(0..<4, with: le32(1))              // HeaderRevision
        header.replaceSubrange(8..<12, with: le32(UInt32(payload.count)))
        // HeaderChecksum over [0:4] + zeroed [4:8] + [8:12]; DataChecksum over payload.
        header.replaceSubrange(4..<8, with: le32(CRC32.crc32(
            header[0..<4] + Data(repeating: 0, count: 4) + header[8..<12])))
        header.replaceSubrange(12..<16, with: le32(CRC32.crc32(payload)))
        if mangle { header[0x04] ^= 0x80 }
        var out = header
        out.append(payload)
        return out
    }

    func testParsesFITCRevision1() throws {
        let region = Self.makeFITC()
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0x1000))
        XCTAssertEqual(oem.offset, 0x1000)
        XCTAssertEqual(oem.headerRevision, 1)
        XCTAssertEqual(oem.dataLength, 0x80)
        XCTAssertEqual(oem.headerCRCStored, CRC32.crc32(
            Data([0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0x80, 0, 0, 0])))
        XCTAssertEqual(oem.headerCRCValid, true)
        XCTAssertEqual(oem.dataCRCValid, true)
        XCTAssertNil(oem.configLength)
        XCTAssertNil(oem.paddingAllFF)
    }

    func testCorruptedFITCHeaderCRCReported() throws {
        let region = Self.makeFITC(true)
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0))
        XCTAssertEqual(oem.headerRevision, 1)
        XCTAssertEqual(oem.headerCRCValid, false)
        XCTAssertEqual(oem.dataLength, 0x80)              // data facts unaffected
        XCTAssertEqual(oem.dataCRCValid, true)
    }

    func testNonRevision1FITCAlphaLayout() throws {
        // CSME 15 TGP alpha layout: no header checksums. Config length u32 at
        // +0, config at +0x04, tail must be 0xFF padding.
        let config = Data((0..<0x20).map { UInt8($0) })
        var region = Data(repeating: 0xFF, count: 0x200)
        region.replaceSubrange(0..<4, with: Self.le32(UInt32(config.count)))
        region.replaceSubrange(4..<(4 + config.count), with: config)
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0))
        // On the alpha layout the first u32 doubles as the config length (and
        // therefore the HeaderRevision read from it is never 1).
        XCTAssertEqual(oem.headerRevision, UInt32(config.count))
        XCTAssertEqual(oem.configLength, config.count)
        XCTAssertEqual(oem.paddingAllFF, true)
        XCTAssertNil(oem.dataLength)
        XCTAssertNil(oem.headerCRCStored)
    }

    func testNonRevision1DirtyPaddingReported() throws {
        let config = Data((0..<0x20).map { UInt8($0) })
        var region = Data(repeating: 0xFF, count: 0x200)
        region.replaceSubrange(0..<4, with: Self.le32(UInt32(config.count)))
        region.replaceSubrange(4..<(4 + config.count), with: config)
        region[0x100] = 0x00                             // dirty the padding tail
        let oem = try XCTUnwrap(FITCParser.parse(in: region, offset: 0,
                                                 size: region.count,
                                                 absoluteOffset: 0))
        XCTAssertEqual(oem.configLength, config.count)
        XCTAssertEqual(oem.paddingAllFF, false)
    }

    func testRegionTooSmallForFITCReturnsNil() {
        XCTAssertNil(FITCParser.parse(in: Data(repeating: 0, count: 0x0F),
                                      offset: 0, size: 0x0F, absoluteOffset: 0))
    }
}
