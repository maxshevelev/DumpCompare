import XCTest
import Foundation
@testable import MEFirmware

/// Phase 9 — CSE MFS volume structural decode. Two synthetic pages reproduce the
/// layout upstream walks: a *System* page whose obfuscated chunk index recovers
/// to 0 (the volume header chunk) and a *Data* page whose `FirstChunkIndex`
/// fixes the System-area size. The volume facts asserted below were cross-checked
/// byte-for-byte against the real CSME 12.0.3 MFS region (DATMAAMBAC0.BIN @0x7000:
/// signature 0x724F6201, volume size 0x58B80, 512 file records, 210 used, FTBL
/// dict/platform/reserved = 1/0/0 → usesFTBL false). The 210 used count is
/// CRC-16-verified ground truth: all 445 physical System chunks of that region
/// validate their stored chunk CRC-16 (over raw data + LE16(index)) under the
/// slot→index pairing this parser uses. Tests never touch the network.
final class MFSTests: XCTestCase {

    // MARK: Fixtures

    /// One System page whose first chunk index de-obfuscates to 0 and carries a
    /// volume header, plus one Data page (first chunk index 1, all slots unused).
    /// Returns the MFS volume bytes with the volume chunk set from `volumeChunk`.
    private static func makeVolume(_ volumeChunk: Data) -> Data {
        let pageSize = 0x2000
        let pageHeaderSize = 0x12
        let chunkAllSize = 0x42

        // System page.
        var system = Data(repeating: 0xFF, count: pageSize)
        system.replaceSubrange(0..<4, with: le32(0xAA55_7887))
        system.replaceSubrange(4..<8, with: le32(1))        // PageNumber
        system.replaceSubrange(8..<12, with: le32(0))       // EraseCount
        system.replaceSubrange(12..<14, with: le16(2))      // NextErasePage
        system.replaceSubrange(14..<16, with: le16(0))      // FirstChunkIndex 0 ⇒ System
        let sysChunkCount = (pageSize - pageHeaderSize - 2) / (2 + chunkAllSize)
        let sysIndexBytes = sysChunkCount * 2 + 2
        // Obfuscated index for chunk 0: stored = Crc16_14(running=0) ^ 0 = 0x0B5B.
        system.replaceSubrange(pageHeaderSize..<(pageHeaderSize + 2), with: le16(0x0B5B))
        for slot in 1...sysChunkCount {                      // unused markers after it
            let at = pageHeaderSize + slot * 2
            system.replaceSubrange(at..<(at + 2), with: le16(0xC000))
        }
        let sysChunkStart = pageHeaderSize + sysIndexBytes
        system.replaceSubrange(sysChunkStart..<(sysChunkStart + volumeChunk.count),
                               with: volumeChunk)

        // Data page: fixes the System chunk count at its FirstChunkIndex (1); all
        // chunk slots unused so it contributes nothing to the System area.
        var data = Data(repeating: 0xFF, count: pageSize)
        data.replaceSubrange(0..<4, with: le32(0xAA55_7887))
        data.replaceSubrange(4..<8, with: le32(2))           // PageNumber
        data.replaceSubrange(14..<16, with: le16(1))         // FirstChunkIndex 1 ⇒ Data

        var out = system
        out.append(data)
        return out
    }

    private static func makeVolumeChunk(dictionary: UInt8 = 0x0A, platform: UInt8 = 0x01,
                                        reserved: UInt16 = 0xABCD, volumeSize: UInt32 = 0x1200,
                                        fileRecords: UInt16 = 7,
                                        fatFirst: UInt16 = 0x0005) -> Data {
        var chunk = Data(repeating: 0x00, count: 0x40)
        chunk.replaceSubrange(0..<4, with: le32(0x724F_6201))    // volume signature
        chunk[4] = dictionary
        chunk[5] = platform
        chunk.replaceSubrange(6..<8, with: le16(reserved))
        chunk.replaceSubrange(8..<12, with: le32(volumeSize))
        chunk.replaceSubrange(12..<14, with: le16(fileRecords))
        // FAT begins right after the 0xE volume header, inside System chunk 0.
        chunk.replaceSubrange(0x0E..<0x10, with: le16(fatFirst))  // record 0 used
        chunk.replaceSubrange(0x10..<0x12, with: le16(0xFFFF))    // record 1 empty
        return chunk
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

    // MARK: Volume decode

    func testParsesVolumeHeaderFromSystemChunkZero() throws {
        let region = Self.makeVolume(Self.makeVolumeChunk())
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))

        XCTAssertEqual(info.systemPageCount, 1)
        XCTAssertEqual(info.dataPageCount, 1)
        XCTAssertTrue(info.volumeSignatureValid)
        XCTAssertEqual(info.volumeSize, 0x1200)
        XCTAssertEqual(info.fileRecordCount, 7)
        XCTAssertEqual(info.usedFileCount, 1)            // record 0 = 0x0005 used
        XCTAssertEqual(info.ftblDictionary, 0x0A)
        XCTAssertEqual(info.ftblPlatform, 0x01)
        XCTAssertEqual(info.ftblReserved, 0xABCD)
        XCTAssertTrue(info.usesFTBL)
        XCTAssertEqual(info.computedVolumeSize, (1 + 122) * 0x40)
    }

    func testLegacyVolumeWithoutFTBLFlags() throws {
        // (dict, platform, reserved) == (1, 0, 0) is the old-style MFS whose
        // FTBLDictionary field is a *revision*, not an FTBL selector — the real
        // DATMAAMBAC0.BIN case (dict 1/plat 0/res 0).
        let region = Self.makeVolume(Self.makeVolumeChunk(dictionary: 1, platform: 0,
                                                          reserved: 0))
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))
        XCTAssertFalse(info.usesFTBL)
        XCTAssertEqual(info.ftblDictionary, 1)
    }

    func testBadVolumeSignatureReportedNotThrown() throws {
        // System chunk 0 is present but not a valid volume header → facts come
        // back with signatureValid false rather than nil/failure.
        var chunk = Self.makeVolumeChunk()
        chunk.replaceSubrange(0..<4, with: Self.le32(0xDEAD_BEEF))
        let region = Self.makeVolume(chunk)
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))
        XCTAssertFalse(info.volumeSignatureValid)
        XCTAssertEqual(info.fileRecordCount, 0)
    }

    // MARK: Detection

    func testNoMFSPagesYieldsNil() {
        let blank = Data(repeating: 0xFF, count: 0x2000)
        XCTAssertNil(MFSParser.parse(in: blank, offset: 0, size: blank.count))
    }

    func testOffsetsOutOfBoundsYieldNil() {
        let region = Self.makeVolume(Self.makeVolumeChunk())
        XCTAssertNil(MFSParser.parse(in: region, offset: region.count, size: 0x2000))
        XCTAssertNil(MFSParser.parse(in: region, offset: -1, size: 0x2000))
        XCTAssertNil(MFSParser.parse(in: region, offset: 0, size: 0x100))   // < one page
    }

    func testCRC16_14TransformVector() {
        // Crc16_14(0) == 0x0B5B — the constant the system-page fixture stores so
        // chunk index 0 de-obfuscates to 0 (verified in Python first).
        XCTAssertEqual(CRC16_14.transform(0), 0x0B5B)
    }

    // MARK: Low-level file walk fixtures

    /// A two-page MFS whose System chunk 0 carries a volume header for
    /// `fileRecords` records plus a FAT, and whose one Data page (first chunk
    /// index 2 → System area = 2 chunks) holds `dataSlotContents` in its used
    /// chunk slots. FAT data-slot `f` (≥ `fileRecords`) maps to Data-page slot
    /// `f − fileRecords`, matching the parser's `sys + f − fileRecords` index.
    private static func makeFileVolume(fileRecords: UInt16,
                                       fat: [Int: UInt16],
                                       dataSlotContents: [Data],
                                       dictionary: UInt8 = 0x0A,
                                       platform: UInt8 = 0x01,
                                       reserved: UInt16 = 0) -> Data {
        // System page with only System chunk index 0 used.
        var system = Data(repeating: 0xFF, count: 0x2000)
        system.replaceSubrange(0..<4, with: le32(0xAA55_7887))
        system.replaceSubrange(4..<8, with: le32(1))
        system.replaceSubrange(12..<14, with: le16(0))
        system.replaceSubrange(14..<16, with: le16(0))         // FirstChunkIndex 0 ⇒ System
        let sysChunkCount = (0x2000 - 0x12 - 2) / (2 + 0x42)
        system.replaceSubrange(0x12..<0x14, with: le16(0x0B5B))   // obfuscated index 0
        for slot in 1...sysChunkCount {
            let at = 0x12 + slot * 2
            system.replaceSubrange(at..<(at + 2), with: le16(0xC000))
        }
        let sysIndexBytes = sysChunkCount * 2 + 2
        // Volume chunk 0 raw (0x40): signature + 0xE header + FAT u16 slots.
        var volume = Data(repeating: 0x00, count: 0x40)
        volume.replaceSubrange(0..<4, with: le32(0x724F_6201))
        volume[4] = dictionary; volume[5] = platform
        volume.replaceSubrange(6..<8, with: le16(reserved))
        volume.replaceSubrange(8..<12, with: le32(0x1200))
        volume.replaceSubrange(12..<14, with: le16(fileRecords))
        // All records empty by default; `fat` overrides record and data slots.
        for record in 0..<Int(fileRecords) {
            let at = 0x0E + record * 2
            volume.replaceSubrange(at..<(at + 2), with: le16(0xFFFF))
        }
        for (slot, value) in fat {
            let at = 0x0E + slot * 2
            precondition(at + 2 <= 0x40)
            volume.replaceSubrange(at..<(at + 2), with: le16(value))
        }
        system.replaceSubrange((0x12 + sysIndexBytes)..<(0x12 + sysIndexBytes + 0x40),
                               with: volume)

        // Data page: first chunk index 2, used slots carry `dataSlotContents`.
        var data = Data(repeating: 0xFF, count: 0x2000)
        data.replaceSubrange(0..<4, with: le32(0xAA55_7887))
        data.replaceSubrange(4..<8, with: le32(2))
        data.replaceSubrange(14..<16, with: le16(2))            // FirstChunkIndex 2 ⇒ Data
        let dataChunkCount = (0x2000 - 0x12) / (1 + 0x42)
        for (slot, content) in dataSlotContents.enumerated() {
            precondition(content.count <= 0x40)
            data[0x12 + slot] = 0x00                            // used chunk marker
            let at = 0x12 + dataChunkCount + slot * 0x42
            data.replaceSubrange(at..<(at + content.count), with: content)
        }
        var out = system
        out.append(data)
        return out
    }

    func testWalksLowLevelFileChainsAcrossFAT() throws {
        // Two used records chain into the two Data-page chunks and end on EOF
        // markers that also give each file's final byte count.
        let region = Self.makeFileVolume(
            fileRecords: 20,
            fat: [0: 20, 1: 21, 20: 6, 21: 4],       // record0→slot20(EOF 6), record1→slot21(EOF 4)
            dataSlotContents: [Data(repeating: 0x41, count: 0x40),   // 'A' chunk
                               Data(repeating: 0x42, count: 0x40)])  // 'B' chunk
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))

        XCTAssertEqual(info.usedFileCount, 2)
        XCTAssertTrue(info.fileChainsIntact)
        XCTAssertEqual(info.files.count, 2)
        XCTAssertEqual(info.files.map(\.index), [0, 1])
        XCTAssertEqual(info.files[0].content, Data(repeating: 0x41, count: 6))
        XCTAssertEqual(info.files[1].content, Data(repeating: 0x42, count: 4))
    }

    func testUsedButCorruptChainIsNonFatalAndFlagged() throws {
        // Record 0's FAT value (a data slot ≥ fileRecords) points at a Data chunk
        // the volume does not carry → the walk stops with what it has and reports
        // the volume's chains as not intact, rather than failing the parse.
        let region = Self.makeFileVolume(
            fileRecords: 20,
            fat: [0: 60],                             // slot 60 → chunk 42, absent
            dataSlotContents: [])
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))

        XCTAssertEqual(info.usedFileCount, 1)
        XCTAssertFalse(info.fileChainsIntact)
        XCTAssertEqual(info.files.count, 1)           // the used record is still listed
        XCTAssertTrue(info.files[0].content.isEmpty)  // but no chunk was reachable
    }

    // MARK: Legacy Configuration record decode (files 6/7)

    /// Build a legacy Configuration stream: a u32 record count then that many
    /// 0x1C `MFS_Config_Record_0x1C` entries. AccessMode / DeployOptions are given
    /// whole so tests can anchor real DATMAAMBAC0 bit values.
    private static func configStream(_ records: [(name: String, accessMode: UInt16,
                                                 deployOptions: UInt16, size: UInt16,
                                                 offset: UInt32)]) -> Data {
        var out = le32(UInt32(records.count))
        for r in records {
            var name = Data(r.name.utf8.prefix(12))
            name.append(Data(repeating: 0, count: 12 - name.count))
            out.append(name)                              // +0x00 FileName[12]
            out.append(le16(0))                           // +0x0C Reserved
            out.append(le16(r.accessMode))                // +0x0E AccessMode
            out.append(le16(r.deployOptions))             // +0x10 DeployOptions
            out.append(le16(r.size))                      // +0x12 FileSize
            out.append(le16(0))                           // +0x14 OwnerUserID
            out.append(le16(0))                           // +0x16 OwnerGroupID
            out.append(le32(r.offset))                    // +0x18 FileOffset
        }
        return out
    }

    func testLegacyConfigurationStreamDecodesRecordFields() throws {
        // Low-level file 6 (Intel Configuration) carries a 60-byte stream: count
        // 2 then two records using DATMAAMBAC0.BIN's real bit values — record 0
        // 'home' (AccessMode 0x116d → folder, UnixRights 0x16D=365) and record 1
        // 'hw_binding' (AccessMode 0x3a0 → File, Integrity set, rights 0x1A0=416,
        // DeployOptions 0x11 → OEMConfigurable, FileSize 1, offset 0x10A4). The
        // whole content fits one Data chunk (EOF marker 60).
        let stream = Self.configStream([
            (name: "home", accessMode: 0x116D, deployOptions: 0, size: 0, offset: 0),
            (name: "hw_binding", accessMode: 0x03A0, deployOptions: 0x11,
             size: 1, offset: 0x10A4),
        ])
        let region = Self.makeFileVolume(
            fileRecords: 20,
            fat: [6: 20, 20: UInt16(stream.count)],      // record 6 → slot 20 (EOF=count)
            dataSlotContents: [stream],
            dictionary: 1, platform: 0, reserved: 0)     // legacy (dict 1/0/0)
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))

        XCTAssertFalse(info.usesFTBL)
        XCTAssertEqual(info.configurations.count, 1)
        XCTAssertEqual(info.configurations[0].owningFile, 6)

        let recs = info.configurations[0].records
        XCTAssertEqual(recs.count, 2)

        let home = recs[0]
        XCTAssertEqual(home.name, "home")
        XCTAssertTrue(home.isFolder)
        XCTAssertEqual(home.unixRights, 365)             // 0x16D
        XCTAssertEqual(home.size, 0)
        XCTAssertEqual(home.offset, 0)
        XCTAssertFalse(home.integrity)
        XCTAssertFalse(home.encryption)
        XCTAssertFalse(home.antiReplay)
        XCTAssertFalse(home.oemConfigurable)
        XCTAssertFalse(home.mcaConfigurable)

        let binding = recs[1]
        XCTAssertEqual(binding.name, "hw_binding")
        XCTAssertFalse(binding.isFolder)
        XCTAssertEqual(binding.unixRights, 416)          // 0x1A0
        XCTAssertTrue(binding.integrity)
        XCTAssertFalse(binding.encryption)
        XCTAssertFalse(binding.antiReplay)
        XCTAssertTrue(binding.oemConfigurable)
        XCTAssertFalse(binding.mcaConfigurable)
        XCTAssertEqual(binding.size, 1)
        XCTAssertEqual(binding.offset, 0x10A4)
    }

    func testFTBLVolumeDoesNotDecodeConfigurationStream() throws {
        // The FTBL layout (usesFTBL true) names its config files through
        // FileTable.dat; its low-level 6/7 content is not a 0x1C stream, so the
        // decode is gated on the legacy volume — configurations stay empty even
        // when file 6 carries bytes.
        let stream = Self.configStream([
            (name: "home", accessMode: 0x116D, deployOptions: 0, size: 0, offset: 0),
        ])
        let region = Self.makeFileVolume(
            fileRecords: 20,
            fat: [6: 20, 20: UInt16(stream.count)],     // FTBL dict 0x0A/0x01 defaults
            dataSlotContents: [stream])
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))

        XCTAssertTrue(info.usesFTBL)
        XCTAssertEqual(info.files.map(\.index), [6])     // the file walked fine…
        XCTAssertTrue(info.configurations.isEmpty)       // …but is not decoded as config
    }

    func testLegacyVolumeWithoutConfigFilesHasEmptyConfigurations() throws {
        // A legacy volume whose present files are none of 6/7 → no configurations.
        let region = Self.makeFileVolume(
            fileRecords: 20,
            fat: [0: 20, 20: 4],                        // only record 0 (1-byte file)
            dataSlotContents: [Data([0xAB])],
            dictionary: 1, platform: 0, reserved: 0)
        let info = try XCTUnwrap(MFSParser.parse(in: region, offset: 0, size: region.count))
        XCTAssertFalse(info.usesFTBL)
        XCTAssertTrue(info.configurations.isEmpty)
    }

    func testConfigStreamTruncatedBeforeItsDeclaredCountDecodesWhatFits() throws {
        // A stream whose declared count exceeds the bytes present decodes the
        // complete records that fit and stops (upstream error-and-continue); a
        // stream shorter than the u32 count field is not a config stream at all.
        let two = Self.configStream([
            (name: "home", accessMode: 0x116D, deployOptions: 0, size: 0, offset: 0),
            (name: "hw_binding", accessMode: 0x03A0, deployOptions: 0x11,
             size: 1, offset: 0x10A4),
        ])
        let cut = Data(two.prefix(4 + 0x1C))            // declares 2, keeps 1 record
        let records = MFSParser.decodeConfigRecords(cut)
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?.first?.name, "home")

        XCTAssertNil(MFSParser.decodeConfigRecords(Data([1, 2, 3])))
        XCTAssertNil(MFSParser.decodeConfigRecords(Data()))
    }
}
