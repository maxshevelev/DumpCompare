import XCTest
import Foundation
@testable import MEFirmware

/// MFS Backup record decode (`MFS_Backup_Header_R0/R1` + `MFS_Backup_Entry`) —
/// the two MFSB branches of upstream `mfs_anl` (MEA.py 7528/7554). No real dump
/// in the oracle set carries an MFSB area (all carry a *normal* MFS partition),
/// so these synthetic fixtures are the sole oracle: each CRC is computed with an
/// *independent* bitwise implementation (R0's IV-0 raw) or the known-vector plain
/// `CRC32.crc32`, never the decoder's own code path, so a shared wrong
/// implementation cannot fake a "valid".
final class MFSBackupTests: XCTestCase {

    // MARK: Fixtures

    private static let signature: UInt32 = 0x4D46_5342      // "MFSB"
    private static let r1HeaderSize = 0x24
    private static let entryHeaderSize = 0x10

    /// Independent bitwise reflected CRC-32 from register IV 0, no final XOR —
    /// the R0 header CRC result upstream computes as `~Crc32.calc(x, 0) & mask`.
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

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
              UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    /// Deterministic test payload of `count` bytes.
    private static func fill(_ count: Int, seed: UInt8 = 0x11) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0) })
    }

    // MARK: R1 fixtures

    /// A self-contained `.r1` blob: 0x10 `MFS_Backup_Entry` header + file data,
    /// with the entry-header CRC (Revision + zeroed EntryCRC32 + Size) and the
    /// data CRC both plain CRC-32.
    private static func makeEntry(_ data: Data) -> Data {
        var blob = Data()
        blob.append(le32(1))                                   // Revision
        blob.append(Data(repeating: 0, count: 4))              // EntryCRC32 (fill later)
        blob.append(le32(UInt32(data.count)))                  // Size
        blob.append(Data(repeating: 0, count: 4))              // DataCRC32 (fill later)
        let headerSpan = blob[0..<4]
            + Data(repeating: 0, count: 4)
            + blob[8..<0x0C]
        blob.replaceSubrange(4..<8, with: le32(CRC32.crc32(headerSpan)))
        blob.replaceSubrange(0x0C..<0x10, with: le32(CRC32.crc32(data)))
        blob.append(data)
        return blob
    }

    /// An `.r1` backup area: 0x24 header (Revision, HeaderCRC32 over
    /// [0:8]+zeroed[8:0xC]+[0xC:0x24], then the 6/9/7 entry offsets/sizes) followed
    /// by the three entry blobs in header order.
    private static func makeR1(data6: Data, data9: Data, data7: Data,
                               revision: UInt32 = 1) -> Data {
        let b6 = makeEntry(data6)
        let b9 = makeEntry(data9)
        let b7 = makeEntry(data7)
        var header = Data(repeating: 0, count: r1HeaderSize)
        header.replaceSubrange(0..<4, with: le32(signature))
        header.replaceSubrange(4..<8, with: le32(revision))
        header.replaceSubrange(0x0C..<0x10, with: le32(UInt32(r1HeaderSize)))       // Entry6Offset
        header.replaceSubrange(0x10..<0x14, with: le32(UInt32(b6.count)))          // Entry6Size
        header.replaceSubrange(0x14..<0x18, with: le32(UInt32(r1HeaderSize + b6.count)))  // Entry9Offset
        header.replaceSubrange(0x18..<0x1C, with: le32(UInt32(b9.count)))          // Entry9Size
        header.replaceSubrange(0x1C..<0x20, with: le32(UInt32(r1HeaderSize + b6.count + b9.count)))  // Entry7Offset
        header.replaceSubrange(0x20..<0x24, with: le32(UInt32(b7.count)))          // Entry7Size
        let headerSpan = header[0..<8]
            + Data(repeating: 0, count: 4)
            + header[0x0C..<r1HeaderSize]
        header.replaceSubrange(8..<0x0C, with: le32(CRC32.crc32(headerSpan)))
        return header + b6 + b9 + b7
    }

    // MARK: R0 fixtures

    /// A normal two-page MFS volume (System page with volume chunk 0, one Data
    /// page) — the target an R0 backup reconstructs into.
    private static func makeMFSVolume(_ volumeChunk: Data) -> Data {
        let pageSize = 0x2000
        let pageHeaderSize = 0x12
        let chunkAllSize = 0x42

        var system = Data(repeating: 0xFF, count: pageSize)
        system.replaceSubrange(0..<4, with: le32(0xAA55_7887))
        system.replaceSubrange(4..<8, with: le32(1))
        system.replaceSubrange(8..<12, with: le32(0))
        system.replaceSubrange(12..<14, with: le16(2))
        system.replaceSubrange(14..<16, with: le16(0))        // FirstChunkIndex 0 ⇒ System
        let sysChunkCount = (pageSize - pageHeaderSize - 2) / (2 + chunkAllSize)
        let sysIndexBytes = sysChunkCount * 2 + 2
        system.replaceSubrange(pageHeaderSize..<(pageHeaderSize + 2), with: le16(0x0B5B))
        for slot in 1...sysChunkCount {
            let at = pageHeaderSize + slot * 2
            system.replaceSubrange(at..<(at + 2), with: le16(0xC000))
        }
        let sysChunkStart = pageHeaderSize + sysIndexBytes
        system.replaceSubrange(sysChunkStart..<(sysChunkStart + volumeChunk.count),
                               with: volumeChunk)

        var data = Data(repeating: 0xFF, count: pageSize)
        data.replaceSubrange(0..<4, with: le32(0xAA55_7887))
        data.replaceSubrange(4..<8, with: le32(2))
        data.replaceSubrange(14..<16, with: le16(1))          // FirstChunkIndex 1 ⇒ Data

        var out = system
        out.append(data)
        return out
    }

    private static func makeVolumeChunk() -> Data {
        var chunk = Data(repeating: 0x00, count: 0x40)
        chunk.replaceSubrange(0..<4, with: le32(0x724F_6201))    // volume signature
        chunk[4] = 0x0A                                          // dictionary
        chunk[5] = 0x01                                          // platform
        chunk.replaceSubrange(6..<8, with: le16(0xABCD))
        chunk.replaceSubrange(8..<12, with: le32(0x1200))
        chunk.replaceSubrange(12..<14, with: le16(7))            // file records
        chunk.replaceSubrange(0x0E..<0x10, with: le16(0x0005))   // record 0 used
        chunk.replaceSubrange(0x10..<0x12, with: le16(0xFFFF))   // record 1 empty
        return chunk
    }

    /// The R0 compaction upstream reverses: every maximal run of 0xFF in `image`
    /// is replaced by `01 03 02 04` + its big-endian length (4 bytes), so the
    /// body never contains a 0xFF byte (hence no 32-byte 0xFF run for the
    /// decoder's end-of-content search to trip on).
    private static func compact(_ image: Data) -> Data {
        var body = Data()
        var i = 0
        while i < image.count {
            if image[i] == 0xFF {
                var j = i
                while j < image.count && image[j] == 0xFF { j += 1 }
                body.append(Data([0x01, 0x03, 0x02, 0x04]))
                body.append(be32(UInt32(j - i)))
                i = j
            } else {
                body.append(image[i])
                i += 1
            }
        }
        return body
    }

    /// An `.r0` backup area: 0x20 header (signature, CRC-32 IV-0 raw over the
    /// body, Reserved all 0xFF) + the body.
    private static func makeR0(_ body: Data) -> Data {
        var area = Data(repeating: 0xFF, count: 0x20)
        area.replaceSubrange(0..<4, with: le32(signature))
        area.replaceSubrange(4..<8, with: le32(crcIV0Raw(body)))
        area.append(body)
        return area
    }

    // MARK: R0 decode

    func testR0ParsesHeaderAndReconstructsIntoValidMFS() throws {
        let target = Self.makeMFSVolume(Self.makeVolumeChunk())
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(
            in: Self.makeR0(Self.compact(target)), offset: 0,
            size: Self.makeR0(Self.compact(target)).count, absoluteOffset: 0x4000))

        XCTAssertEqual(backup.offset, 0x4000)
        XCTAssertEqual(backup.format, .r0)
        XCTAssertEqual(backup.reservedAllFF, true)
        XCTAssertEqual(backup.headerCRCValid, true)
        XCTAssertEqual(backup.reconstructedVolumeParses, true)
        XCTAssertNil(backup.headerRevision)
        XCTAssertNil(backup.headerRevisionValid)
        XCTAssertTrue(backup.entries.isEmpty)
    }

    func testR0ReconstructionRoundTripsTheCompaction() {
        let target = Self.makeMFSVolume(Self.makeVolumeChunk())
        XCTAssertEqual(MFSBackupDecoder.reconstructR0Body(Self.compact(target)), target)
    }

    func testR0CorruptedBodyCRCReported() throws {
        var area = Self.makeR0(Self.compact(Self.makeMFSVolume(Self.makeVolumeChunk())))
        area[0x20 + 0x10] ^= 0xFF                              // corrupt a body byte
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                           size: area.count, absoluteOffset: 0))
        XCTAssertEqual(backup.format, .r0)
        XCTAssertEqual(backup.headerCRCValid, false)
    }

    func testR0BodyThatReconstructsButNotIntoMFSIsFalse() throws {
        // A 0x400 body with a *valid* header CRC but no structure: reconstruction
        // yields a page of 0x55 — no MFS page tags — so it does not parse.
        let body = Data(repeating: 0x55, count: 0x400)
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: Self.makeR0(body), offset: 0,
                                                          size: 0x20 + body.count,
                                                          absoluteOffset: 0))
        XCTAssertEqual(backup.headerCRCValid, true)
        XCTAssertEqual(backup.reconstructedVolumeParses, false)
    }

    // MARK: R1 decode

    func testR1ParsesHeaderAndThreeEntries() throws {
        let d6 = Self.fill(0x10), d9 = Self.fill(0x20, seed: 0x22), d7 = Self.fill(0x30, seed: 0x33)
        let area = Self.makeR1(data6: d6, data9: d9, data7: d7)
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0x1000))

        XCTAssertEqual(backup.offset, 0x1000)
        XCTAssertEqual(backup.format, .r1)
        XCTAssertNil(backup.reservedAllFF)
        XCTAssertNil(backup.reconstructedVolumeParses)
        XCTAssertEqual(backup.headerRevision, 1)
        XCTAssertEqual(backup.headerRevisionValid, true)
        XCTAssertEqual(backup.headerCRCValid, true)

        XCTAssertEqual(backup.entries.count, 3)
        XCTAssertEqual(backup.entries.map { $0.fileIndex }, [6, 9, 7])
        // Blob sizes are header + data; entry-9/7 blob offsets accumulate.
        let b6Size = Self.entryHeaderSize + d6.count          // 0x10 + 0x10
        let e9Offset = Self.r1HeaderSize + b6Size
        let b9Size = Self.entryHeaderSize + d9.count          // 0x10 + 0x20
        let e7Offset = Self.r1HeaderSize + b6Size + b9Size
        let b7Size = Self.entryHeaderSize + d7.count          // 0x10 + 0x30
        XCTAssertEqual(backup.entries[0].blobOffset, Self.r1HeaderSize)
        XCTAssertEqual(backup.entries[0].blobSize, b6Size)
        XCTAssertEqual(backup.entries[1].blobOffset, e9Offset)
        XCTAssertEqual(backup.entries[1].blobSize, b9Size)
        XCTAssertEqual(backup.entries[2].blobOffset, e7Offset)
        XCTAssertEqual(backup.entries[2].blobSize, b7Size)
        for (i, d) in [d6, d9, d7].enumerated() {
            XCTAssertEqual(backup.entries[i].revision, 1)
            XCTAssertEqual(backup.entries[i].revisionValid, true)
            XCTAssertEqual(backup.entries[i].headerCRCValid, true)
            XCTAssertEqual(backup.entries[i].dataSize, d.count)
            XCTAssertEqual(backup.entries[i].dataCRCValid, true)
        }
    }

    func testR1CorruptedHeaderCRCReported() throws {
        var area = Self.makeR1(data6: Self.fill(0x10), data9: Self.fill(0x20),
                               data7: Self.fill(0x30))
        area[0x08] ^= 0xFF                                   // stored HeaderCRC32 byte
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0))
        XCTAssertEqual(backup.headerCRCValid, false)
        XCTAssertEqual(backup.headerRevisionValid, true)
        XCTAssertTrue(backup.entries.allSatisfy { $0.headerCRCValid && $0.dataCRCValid })
    }

    func testR1HeaderRevisionMismatchReported() throws {
        let area = Self.makeR1(data6: Self.fill(0x10), data9: Self.fill(0x20),
                               data7: Self.fill(0x30), revision: 2)
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0))
        XCTAssertEqual(backup.headerRevision, 2)
        XCTAssertEqual(backup.headerRevisionValid, false)
        XCTAssertEqual(backup.headerCRCValid, true)          // span recomputed for rev 2
    }

    func testR1EntryHeaderCRCInvalidIsolated() throws {
        var area = Self.makeR1(data6: Self.fill(0x10), data9: Self.fill(0x20),
                               data7: Self.fill(0x30))
        area[Self.r1HeaderSize + 0x04] ^= 0xFF               // entry 6 EntryCRC32
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0))
        XCTAssertEqual(backup.entries[0].fileIndex, 6)
        XCTAssertEqual(backup.entries[0].headerCRCValid, false)
        XCTAssertEqual(backup.entries[0].revisionValid, true)
        XCTAssertEqual(backup.entries[0].dataCRCValid, true)
        XCTAssertTrue(backup.entries[1].headerCRCValid)
        XCTAssertTrue(backup.entries[2].headerCRCValid)
    }

    func testR1EntryDataCRCInvalidIsolated() throws {
        var area = Self.makeR1(data6: Self.fill(0x10), data9: Self.fill(0x20),
                               data7: Self.fill(0x30))
        // Entry 9 blob: header 0x10 + data; flip the 4th data byte.
        let entry9BlobStart = Self.r1HeaderSize + Self.entryHeaderSize + 0x10
        area[entry9BlobStart + 0x10 + 0x03] ^= 0xFF
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0))
        let e9 = backup.entries[1]
        XCTAssertEqual(e9.fileIndex, 9)
        XCTAssertEqual(e9.dataCRCValid, false)
        XCTAssertEqual(e9.headerCRCValid, true)
        XCTAssertTrue(backup.entries[0].dataCRCValid)
        XCTAssertTrue(backup.entries[2].dataCRCValid)
    }

    func testR1OutOfRangeEntryReportedNotThrown() throws {
        // Entry 7 points far outside the area: its validity flags clear but the
        // backup (and entries 6/9) still decode. The header sizes entries 6/9
        // from their real blobs and only entry 7 is bogus.
        let e6 = Self.makeEntry(Self.fill(0x10))
        let e9 = Self.makeEntry(Self.fill(0x20))
        let e7Offset: UInt32 = 0xFFFF_FF00
        var header = Data(repeating: 0, count: Self.r1HeaderSize)
        header.replaceSubrange(0..<4, with: Self.le32(Self.signature))
        header.replaceSubrange(4..<8, with: Self.le32(1))
        header.replaceSubrange(0x0C..<0x10, with: Self.le32(UInt32(Self.r1HeaderSize)))
        header.replaceSubrange(0x10..<0x14, with: Self.le32(UInt32(e6.count)))
        header.replaceSubrange(0x14..<0x18, with: Self.le32(UInt32(Self.r1HeaderSize + e6.count)))
        header.replaceSubrange(0x18..<0x1C, with: Self.le32(UInt32(e9.count)))
        header.replaceSubrange(0x1C..<0x20, with: Self.le32(e7Offset))
        header.replaceSubrange(0x20..<0x24, with: Self.le32(0x10))
        let headerSpan = header[0..<8]
            + Data(repeating: 0, count: 4)
            + header[0x0C..<Self.r1HeaderSize]
        header.replaceSubrange(8..<0x0C, with: Self.le32(CRC32.crc32(headerSpan)))
        let area = header + e6 + e9
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0))
        XCTAssertEqual(backup.headerCRCValid, true)
        XCTAssertEqual(backup.entries[0].dataCRCValid, true)
        XCTAssertEqual(backup.entries[1].dataCRCValid, true)
        XCTAssertEqual(backup.entries[2].fileIndex, 7)
        XCTAssertEqual(backup.entries[2].blobOffset, 0xFFFF_FF00)
        XCTAssertEqual(backup.entries[2].revisionValid, false)
        XCTAssertEqual(backup.entries[2].headerCRCValid, false)
        XCTAssertEqual(backup.entries[2].dataCRCValid, false)
    }

    // MARK: Detection

    func testNonMFSBAreaReturnsNil() {
        // A normal MFS region (page tag) is not a backup.
        let normal = Data([0x87, 0x78, 0x55, 0xAA]) + Data(repeating: 0xFF, count: 0x20)
        XCTAssertNil(MFSBackupDecoder.parse(in: normal, offset: 0,
                                            size: normal.count, absoluteOffset: 0))
        // Erased / blank area.
        let blank = Data(repeating: 0xFF, count: 0x40)
        XCTAssertNil(MFSBackupDecoder.parse(in: blank, offset: 0,
                                            size: blank.count, absoluteOffset: 0))
    }

    func testRegionTooSmallOrOutOfBoundsReturnsNil() {
        XCTAssertNil(MFSBackupDecoder.parse(in: Data(repeating: 0, count: 0x10), offset: 0,
                                            size: 0x10, absoluteOffset: 0))
        XCTAssertNil(MFSBackupDecoder.parse(in: Data(repeating: 0, count: 0x40), offset: 0x20,
                                            size: 0x40, absoluteOffset: 0))
    }

    func testOutOfRangeHeaderOffsetsStayGraceful() throws {
        // R1 signature but only 0x20 bytes — shorter than the 0x24 R1 header:
        // header fields read nil → zeros, no crash.
        var area = Data(repeating: 0x00, count: 0x20)
        area.replaceSubrange(0..<4, with: Self.le32(Self.signature))
        let backup = try XCTUnwrap(MFSBackupDecoder.parse(in: area, offset: 0,
                                                          size: area.count, absoluteOffset: 0))
        XCTAssertEqual(backup.format, .r1)
        XCTAssertEqual(backup.headerRevisionValid, false)
        XCTAssertFalse(backup.entries.allSatisfy { $0.headerCRCValid })
    }
}
