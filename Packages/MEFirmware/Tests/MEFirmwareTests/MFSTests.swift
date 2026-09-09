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

    // MARK: Home Directory / Integrity decode fixtures

    /// One `MFS_Home_Record_0x18`/`0x1C` row: FileInfo u32 @0 (fileIndex 12b,
    /// IntegritySalt 16b @12, FileSystemID 4b @28), AccessMode u16 @4 (rights
    /// 9b + Integrity/Encryption/AntiReplay/KeyType/RecordType bits), owner ids,
    /// UnknownSalt u16(s) @0xA, NUL-padded FileName[12] as the record's last
    /// 12 bytes.
    private static func homeRow(name: String, fileIndex: Int = 8, folder: Bool = false,
                                integrity: Bool = false, encryption: Bool = false,
                                antiReplay: Bool = false, rights: Int = 0x1ED,
                                fsid: Int = 1, keyType: Int = 1,
                                recordSize: Int = 0x1C, salt: [UInt16] = []) -> Data {
        let saltWords = recordSize == 0x1C ? 3 : 1
        var salt = salt
        if salt.isEmpty {
            salt = saltWords == 3 ? [0x1111, 0x2222, 0x3333] : [0x1111]
        }
        precondition(salt.count == saltWords, "salt word count vs record size")
        let fileInfo = UInt32(fileIndex & 0xFFF)
            | (UInt32(0x1234 & 0xFFFF) << 12)      // IntegritySalt
            | (UInt32(fsid & 0xF) << 28)           // FileSystemID
        var access = UInt16(rights & 0x1FF)        // UnixRights
        if integrity { access |= 1 << 9 }
        if encryption { access |= 1 << 10 }
        if antiReplay { access |= 1 << 11 }
        access |= UInt16((keyType & 1) << 13)
        if folder { access |= 1 << 14 }            // RecordType (0 File, 1 Folder)
        var out = Data()
        out.append(le32(fileInfo))
        out.append(le16(access))
        out.append(le16(0x00AA))                   // OwnerUserID
        out.append(le16(0x00BB))                   // OwnerGroupID
        for word in salt { out.append(le16(word)) }
        var nameBytes = Data(name.utf8.prefix(12))
        nameBytes.append(Data(repeating: 0, count: 12 - nameBytes.count))
        out.append(nameBytes)
        precondition(out.count == recordSize, "home row size")
        return out
    }

    /// A whole trailing `MFS_Integrity_Table` of `size` bytes (0x28/0x34) with
    /// the HMAC, Flags, AR nonce words and AES-GCM/CTR nonce field placed at
    /// their layout offsets. For 0x34 the `arRandom`/`arCounter` words overwrite
    /// the leading 8 bytes of the 16-byte `nonce` region, as they do upstream.
    private static func integrityTable(size: Int, flags: UInt32, hmac: Data,
                                       nonce: Data, arRandom: UInt32 = 0,
                                       arCounter: UInt32 = 0) -> Data {
        var out = Data(repeating: 0, count: size)
        out.replaceSubrange(0..<min(hmac.count, size), with: hmac)
        if size == 0x28 {
            out.replaceSubrange(0x10..<0x14, with: le32(flags))
            out.replaceSubrange(0x1C..<0x28, with: nonce)
            out.replaceSubrange(0x14..<0x18, with: le32(arRandom))
            out.replaceSubrange(0x18..<0x1C, with: le32(arCounter))
        } else {
            out.replaceSubrange(0x20..<0x24, with: le32(flags))
            out.replaceSubrange(0x24..<0x34, with: nonce)
            out.replaceSubrange(0x24..<0x28, with: le32(arRandom))    // word 0
            out.replaceSubrange(0x28..<0x2C, with: le32(arCounter))   // word 1
        }
        return out
    }

    // MARK: Layout selectors (get_sec_hdr_size / get_vfs_start_0)

    func testSecHeaderSizeLayoutSelectors() {
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSME", major: 14, minor: 5, platform: 0), 0x34)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSSPS", major: 4, minor: 4, platform: 0), 0x28)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSSPS", major: 5, minor: 9, platform: 10), 0x28)
        // CSSPS 5 at any platform but 10 falls through to the 0x34 row.
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSSPS", major: 5, minor: 9, platform: 9), 0x34)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSME", major: 11, minor: 8, platform: 0), 0x34)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSTXE", major: 3, minor: 0, platform: 0), 0x34)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSME", major: 12, minor: 0, platform: 0), 0x28)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSME", major: 15, minor: 0, platform: 0), 0x28)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "CSME", major: 13, minor: 30, platform: 0), 0x28)
        XCTAssertEqual(MFSHomeDecoder.secHeaderSize(variant: "GSC", major: 1, minor: 0, platform: 0), 0x28)  // default
    }

    func testVfsStartsAtZeroLayoutSelectors() {
        XCTAssertTrue(MFSHomeDecoder.vfsStartsAtZero(variant: "CSME", major: 13, minor: 30))
        XCTAssertTrue(MFSHomeDecoder.vfsStartsAtZero(variant: "CSME", major: 15, minor: 40))
        XCTAssertTrue(MFSHomeDecoder.vfsStartsAtZero(variant: "CSME", major: 16, minor: 0))
        XCTAssertFalse(MFSHomeDecoder.vfsStartsAtZero(variant: "CSME", major: 11, minor: 8))
        XCTAssertFalse(MFSHomeDecoder.vfsStartsAtZero(variant: "CSME", major: 12, minor: 0))
        XCTAssertFalse(MFSHomeDecoder.vfsStartsAtZero(variant: "CSME", major: 13, minor: 29))
        XCTAssertFalse(MFSHomeDecoder.vfsStartsAtZero(variant: "CSSPS", major: 6, minor: 0))
        XCTAssertTrue(MFSHomeDecoder.vfsStartsAtZero(variant: "GSC", major: 1, minor: 0))  // default
    }

    // MARK: MFS_Integrity_Table decode (0x28 / 0x34)

    func testIntegrityTable028DecodesFields() throws {
        var hmac = Data(repeating: 0, count: 16)
        for i in 0..<16 { hmac[i] = UInt8(i) }
        let nonce = Data(repeating: 0xAB, count: 12)
        // AR(0x2) + Encryption bit3(0x8) + ARIndex 5<<11 + SVN 3<<22.
        let flags: UInt32 = 0x2 | 0x8 | (5 << 11) | (3 << 22)   // 0xC0280A
        let table = Self.integrityTable(size: 0x28, flags: flags, hmac: hmac,
                                        nonce: nonce,
                                        arRandom: 0x1122_3344,
                                        arCounter: 0x5566_7788)
        let t = try XCTUnwrap(MFSHomeDecoder.integrityTable(table))
        XCTAssertEqual(t.size, 0x28)
        XCTAssertEqual(t.hmacHex, "000102030405060708090A0B0C0D0E0F")
        XCTAssertEqual(t.flagsRaw, 0xC0280A)
        XCTAssertTrue(t.antiReplayProtection)
        XCTAssertTrue(t.encryptionProtection)      // 0x28 Encryption is Flags bit 3
        XCTAssertEqual(t.antiReplayIndex, 5)
        XCTAssertEqual(t.securityVersion, 3)
        XCTAssertEqual(t.arRandom, 0x1122_3344)
        XCTAssertEqual(t.arCounter, 0x5566_7788)
        XCTAssertEqual(t.nonceHex, "ABABABABABABABABABABABAB")

        let idle = try XCTUnwrap(MFSHomeDecoder.integrityTable(
            Self.integrityTable(size: 0x28, flags: 0, hmac: Data(repeating: 0, count: 16),
                                nonce: Data(repeating: 0, count: 12))))
        XCTAssertFalse(idle.antiReplayProtection)
        XCTAssertFalse(idle.encryptionProtection)
        XCTAssertEqual(idle.antiReplayIndex, 0)
        XCTAssertEqual(idle.securityVersion, 0)
    }

    func testIntegrityTable034DecodesFields() throws {
        var hmac = Data(repeating: 0, count: 32)
        for i in 0..<32 { hmac[i] = UInt8(i) }
        let nonce = Data(repeating: 0x11, count: 16)
        // AR(0x2) + Encryption bit2(0x4) + ARIndex 7<<10 + SVN 4<<21.
        let flags: UInt32 = 0x2 | 0x4 | (7 << 10) | (4 << 21)   // 0x801C06
        let table = Self.integrityTable(size: 0x34, flags: flags, hmac: hmac,
                                        nonce: nonce,
                                        arRandom: 0xDEAD_BEEF,
                                        arCounter: 0xCAFE_BABE)
        let t = try XCTUnwrap(MFSHomeDecoder.integrityTable(table))
        XCTAssertEqual(t.size, 0x34)
        XCTAssertEqual(t.hmacHex, "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
        XCTAssertEqual(t.flagsRaw, 0x801C06)
        XCTAssertTrue(t.antiReplayProtection)
        XCTAssertTrue(t.encryptionProtection)      // 0x34 Encryption is Flags bit 2
        XCTAssertEqual(t.antiReplayIndex, 7)
        XCTAssertEqual(t.securityVersion, 4)
        XCTAssertEqual(t.arRandom, 0xDEAD_BEEF)
        XCTAssertEqual(t.arCounter, 0xCAFE_BABE)
        // The 16-byte nonce region carries the AR words up front.
        XCTAssertEqual(t.nonceHex, "EFBEADDEBEBAFECA1111111111111111")
    }

    func testIntegrityTableRejectsOtherLengths() {
        XCTAssertNil(MFSHomeDecoder.integrityTable(Data(repeating: 0, count: 0x2C)))
        XCTAssertNil(MFSHomeDecoder.integrityTable(Data()))
    }

    // MARK: homeRecordSize marker detection

    func testHomeRecordSizeDetectedFromMarkerPair() {
        // 0x18 layout: Current '.' at rec0's name offset 12; the '..' row's
        // second dot lands 0x18 bytes later (its first dot is followed by a dot,
        // not padding) → size 0x18.
        var c18 = Self.homeRow(name: ".", recordSize: 0x18)
        c18.append(Self.homeRow(name: "..", recordSize: 0x18))
        XCTAssertEqual(MFSHomeDecoder.homeRecordSize(in: c18), 0x18)

        // 0x1C layout: markers at 16 and 45 → size 0x1C.
        var c1C = Self.homeRow(name: ".", recordSize: 0x1C)
        c1C.append(Self.homeRow(name: "..", recordSize: 0x1C))
        XCTAssertEqual(MFSHomeDecoder.homeRecordSize(in: c1C), 0x1C)
    }

    func testHomeRecordSizeNilWithoutTwoMarkers() {
        // A lone '.' row is a single marker → no resolvable record size.
        XCTAssertNil(MFSHomeDecoder.homeRecordSize(in: Self.homeRow(name: ".", recordSize: 0x1C)))
        XCTAssertNil(MFSHomeDecoder.homeRecordSize(in: Data()))
        XCTAssertNil(MFSHomeDecoder.homeRecordSize(in: Data(repeating: 0x2E, count: 32)))
    }

    // MARK: reservedIntegrity (upstream 7901–7929)

    func testReservedIntegrityCSME12IncludesQuotaFile() throws {
        let hmac = Data(repeating: 0x5A, count: 16)
        let nonce = Data(repeating: 0x6B, count: 12)
        let table = Self.integrityTable(size: 0x28, flags: 0x2, hmac: hmac, nonce: nonce)
        // File 1 too short to carry a table; files 2/3 (0xC4 data) and 5 (0x208
        // data, quota — CSME ≥ 12 does carry one).
        let files = [
            MFSLowLevelFile(index: 1, content: Data(repeating: 0, count: 0x10)),
            MFSLowLevelFile(index: 2, content: Data(repeating: 0x22, count: 0xC4) + table),
            MFSLowLevelFile(index: 3, content: Data(repeating: 0x33, count: 0xC4) + table),
            MFSLowLevelFile(index: 5, content: Data(repeating: 0x55, count: 0x208) + table),
        ]
        let result = MFSHomeDecoder.reservedIntegrity(
            files: files, variant: "CSME", major: 12, minor: 0,
            hotfix: 0, platform: 0, isAFS: false)
        XCTAssertEqual(result.map(\.fileIndex), [2, 3, 5])
        XCTAssertEqual(result.map(\.contentSize), [0xC4, 0xC4, 0x208])
        XCTAssertEqual(result.map { $0.integrity.size }, [0x28, 0x28, 0x28])
    }

    func testReservedIntegrityHonorsRoleExemptions() throws {
        let hmac = Data(repeating: 0xA5, count: 32)
        let nonce = Data(repeating: 0x0F, count: 16)
        let table = Self.integrityTable(size: 0x34, flags: 0, hmac: hmac, nonce: nonce)
        let files = [
            MFSLowLevelFile(index: 2, content: Data(repeating: 0x22, count: 0xC4) + table),
            MFSLowLevelFile(index: 4, content: Data(repeating: 0x44, count: 0x80) + table),
            MFSLowLevelFile(index: 5, content: Data(repeating: 0x55, count: 0x208) + table),
        ]
        // CSME 11, AFS: file 5 (quota, major < 12) and file 4 (SVN Migration at
        // CSTXE/AFS) carry no Integrity → only file 2 is listed.
        let afs = MFSHomeDecoder.reservedIntegrity(
            files: files, variant: "CSME", major: 11, minor: 8,
            hotfix: 0, platform: 0, isAFS: true)
        XCTAssertEqual(afs.map(\.fileIndex), [2])
        // Same layout, not AFS → file 4 now carries; file 5 stays exempt.
        let nonAFS = MFSHomeDecoder.reservedIntegrity(
            files: files, variant: "CSME", major: 11, minor: 8,
            hotfix: 0, platform: 0, isAFS: false)
        XCTAssertEqual(nonAFS.map(\.fileIndex), [2, 4])
    }

    func testReservedIntegritySkipsFilesOutsideOneToFive() throws {
        let table = Self.integrityTable(size: 0x28, flags: 0, hmac: Data(repeating: 0x5A, count: 16),
                                        nonce: Data(repeating: 0x6B, count: 12))
        let files = [
            MFSLowLevelFile(index: 8, content: Data(repeating: 0xAB, count: 0x40) + table),
            MFSLowLevelFile(index: 9, content: Data(repeating: 0xCD, count: 0x40) + table),
        ]
        let result = MFSHomeDecoder.reservedIntegrity(
            files: files, variant: "CSME", major: 12, minor: 0,
            hotfix: 0, platform: 0, isAFS: false)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: full Home Directory decode (mfs_home_anl)

    func testHomeDirectoryRecursesIntoFolderFiles() throws {
        let rs = 0x1C, sec = 0x28
        let table = Self.integrityTable(size: 0x28, flags: 0,
                                        hmac: Data(repeating: 0x5A, count: 16),
                                        nonce: Data(repeating: 0x6B, count: 12))
        // Pointed files: 'data0' → file 3 (5 bytes + Integrity), 'inner' → file 6.
        let file3 = Data(repeating: 0x44, count: 5) + table
        let file6 = Data(repeating: 0x49, count: 3) + table
        // Folder file 4's own rows ('.', '..', then 'inner' → file 6) + its table.
        var file4 = Self.homeRow(name: ".", fileIndex: 8, folder: true, recordSize: rs)
        file4.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: rs))
        file4.append(Self.homeRow(name: "inner", fileIndex: 6, integrity: true, recordSize: rs))
        file4.append(table)
        // File-8 root rows ('.', '..', 'data0', 'folder') + its own table.
        var file8 = Self.homeRow(name: ".", fileIndex: 8, folder: true, recordSize: rs)
        file8.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: rs))
        file8.append(Self.homeRow(name: "data0", fileIndex: 3, integrity: true, recordSize: rs))
        file8.append(Self.homeRow(name: "folder", fileIndex: 4, folder: true, integrity: true, recordSize: rs))
        file8.append(table)

        let files = [
            MFSLowLevelFile(index: 3, content: file3),
            MFSLowLevelFile(index: 4, content: file4),
            MFSLowLevelFile(index: 6, content: file6),
            MFSLowLevelFile(index: 8, content: file8),
        ]
        let home = try XCTUnwrap(MFSHomeDecoder.homeDirectory(
            files: files, variant: "CSME", major: 12, minor: 0,
            hotfix: 0, platform: 0))
        XCTAssertEqual(home.homeRecordSize, rs)
        XCTAssertEqual(home.rootRecordCount, 4)          // markers + two named rows
        XCTAssertEqual(home.integrity?.size, sec)        // file-8's own trailing table
        XCTAssertEqual(home.entries.count, 2)            // markers skipped

        let data0 = home.entries[0]
        XCTAssertEqual(data0.name, "data0")
        XCTAssertEqual(data0.fileIndex, 3)
        XCTAssertFalse(data0.isFolder)
        XCTAssertTrue(data0.integrityProtection)
        XCTAssertEqual(data0.integrity?.size, sec)
        XCTAssertEqual(data0.size, 5)                    // content minus its table

        let folder = home.entries[1]
        XCTAssertEqual(folder.name, "folder")
        XCTAssertEqual(folder.fileIndex, 4)
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.children.count, 1)
        let inner = folder.children[0]
        XCTAssertEqual(inner.name, "inner")
        XCTAssertEqual(inner.fileIndex, 6)
        XCTAssertEqual(inner.size, 3)
        XCTAssertEqual(inner.integrity?.size, sec)
    }

    func testHomeDirectorySurfacesUnknownSalt() throws {
        // The 0x1C UnknownSalt u16[3] @0xA (6 LE bytes) decodes into one integer.
        var file8 = Self.homeRow(name: ".", recordSize: 0x1C)
        file8.append(Self.homeRow(name: "..", recordSize: 0x1C))
        file8.append(Self.homeRow(name: "salt", fileIndex: 3,
                                  recordSize: 0x1C, salt: [0x1111, 0x2222, 0x3333]))
        file8.append(Self.integrityTable(size: 0x28, flags: 0,
                                         hmac: Data(repeating: 0x5A, count: 16),
                                         nonce: Data(repeating: 0x6B, count: 12)))
        let files = [MFSLowLevelFile(index: 3, content: Data(repeating: 0, count: 4)),
                     MFSLowLevelFile(index: 8, content: file8)]
        let home = try XCTUnwrap(MFSHomeDecoder.homeDirectory(
            files: files, variant: "CSME", major: 12, minor: 0,
            hotfix: 0, platform: 0))
        XCTAssertEqual(home.entries[0].name, "salt")
        XCTAssertEqual(home.entries[0].unknownSalt, 0x3333_2222_1111)
    }

    func testHomeFolderSelfReferenceTerminatesWithEmptyChildren() throws {
        // A folder whose own file's rows point back at that same folder — the
        // self-reference a literal transcription would recurse on. The engine's
        // recursion-stack cycle guard yields empty children on the re-entry.
        let rs = 0x1C
        let table = Self.integrityTable(size: 0x28, flags: 0,
                                        hmac: Data(repeating: 0x5A, count: 16),
                                        nonce: Data(repeating: 0x6B, count: 12))
        // file 30 (a folder file) holds rows '.', '..', 'self' → file 30 again.
        // Folder rows are Integrity-protected, so file 30 carries its own table.
        var file30 = Self.homeRow(name: ".", fileIndex: 30, folder: true, recordSize: rs)
        file30.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: rs))
        file30.append(Self.homeRow(name: "self", fileIndex: 30, folder: true,
                                   integrity: true, recordSize: rs))
        file30.append(table)
        var file8 = Self.homeRow(name: ".", fileIndex: 8, folder: true, recordSize: rs)
        file8.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: rs))
        file8.append(Self.homeRow(name: "outer", fileIndex: 30, folder: true,
                                  integrity: true, recordSize: rs))
        file8.append(table)
        let files = [MFSLowLevelFile(index: 8, content: file8),
                     MFSLowLevelFile(index: 30, content: file30)]
        let home = try XCTUnwrap(MFSHomeDecoder.homeDirectory(
            files: files, variant: "CSME", major: 12, minor: 0,
            hotfix: 0, platform: 0))
        let outer = home.entries[0]
        XCTAssertEqual(outer.name, "outer")
        XCTAssertEqual(outer.children.count, 1)
        let inner = outer.children[0]
        XCTAssertEqual(inner.name, "self")
        XCTAssertTrue(inner.isFolder)
        XCTAssertTrue(inner.children.isEmpty)      // cycle guard stopped the re-walk
    }

    func testNulPrefixDirtyMarkerIsTruncatedAndSkipped() throws {
        // CSME 12 file-25's dirty row is named ".\0faults…" — its FileName begins
        // with the Current '.' marker then NULs. Truncating at the first NUL makes
        // it "." → treated as the marker it is, never surfaced (a literal UTF-8
        // decode would keep the trailing NULs, misclassify it as a real row and,
        // as a folder, recurse forever). Termination proof: a finite fixture decodes
        // cleanly and surfaces only the real 'bup' row.
        let rs = 0x1C
        let table = Self.integrityTable(size: 0x28, flags: 0,
                                        hmac: Data(repeating: 0x5A, count: 16),
                                        nonce: Data(repeating: 0x6B, count: 12))
        var file8 = Self.homeRow(name: ".", fileIndex: 8, folder: true, recordSize: rs)
        file8.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: rs))
        // The dirty self-referencing folder of DATMA file 25.
        file8.append(Self.homeRow(name: ".\u{0}faults", fileIndex: 25, folder: true, recordSize: rs))
        file8.append(Self.homeRow(name: "bup", fileIndex: 3, recordSize: rs))
        file8.append(table)
        // file 25, when (wrongly) reached, would hold an identical dirty row.
        var file25 = Self.homeRow(name: ".", fileIndex: 25, folder: true, recordSize: rs)
        file25.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: rs))
        file25.append(Self.homeRow(name: ".\u{0}faults", fileIndex: 25, folder: true, recordSize: rs))
        file25.append(table)
        let files = [MFSLowLevelFile(index: 3, content: Data(repeating: 0x42, count: 2)),
                     MFSLowLevelFile(index: 25, content: file25),
                     MFSLowLevelFile(index: 8, content: file8)]
        let home = try XCTUnwrap(MFSHomeDecoder.homeDirectory(
            files: files, variant: "CSME", major: 12, minor: 0,
            hotfix: 0, platform: 0))
        // Markers + dirty row skipped; only 'bup' is a real row. No NUL in any name.
        XCTAssertEqual(home.entries.count, 1)
        XCTAssertEqual(home.entries[0].name, "bup")
        XCTAssertEqual(home.entries[0].size, 2)
        XCTAssertTrue(home.entries.allSatisfy { !$0.name.contains("\u{0}") })
    }

    func testHomeDirectoryNilCases() throws {
        let table = Self.integrityTable(size: 0x28, flags: 0,
                                        hmac: Data(repeating: 0x5A, count: 16),
                                        nonce: Data(repeating: 0x6B, count: 12))
        // vfs_starts_at_0 volume (CSME 15): file-8 is named via FTBL, never a home.
        var file8 = Self.homeRow(name: ".", fileIndex: 8, folder: true, recordSize: 0x1C)
        file8.append(Self.homeRow(name: "..", fileIndex: 0, recordSize: 0x1C))
        file8.append(table)
        XCTAssertNil(MFSHomeDecoder.homeDirectory(
            files: [MFSLowLevelFile(index: 8, content: file8)],
            variant: "CSME", major: 15, minor: 40, hotfix: 0, platform: 0))
        // Absent file 8.
        XCTAssertNil(MFSHomeDecoder.homeDirectory(
            files: [MFSLowLevelFile(index: 3, content: Data([0]))],
            variant: "CSME", major: 12, minor: 0, hotfix: 0, platform: 0))
        // File 8 with a single marker → no resolvable record size.
        XCTAssertNil(MFSHomeDecoder.homeDirectory(
            files: [MFSLowLevelFile(index: 8, content: Self.homeRow(name: ".", fileIndex: 8, folder: true, recordSize: 0x1C))],
            variant: "CSME", major: 12, minor: 0, hotfix: 0, platform: 0))
    }

}

/// `MFSStateDecoder.state` — the default-output row 17 File System State,
/// computed from a volume's present file-index set exactly as upstream decides
/// on `mfs_parsed_idx` (MEA.py 7489–7493). `usesFTBL` mirrors the
/// `mfs_found and not param.cse_unpack` gate on a *non*-legacy volume.
final class MFSStateDecoderTests: XCTestCase {
    func testLegacyIndexSetMapsToInitialized() {
        // Any present file in {0,1,2,3,4,5,8} marks a legacy volume Initialized —
        // the reserved directories exist on it (typical CSME 11–14).
        for index in [0, 1, 2, 3, 4, 5, 8] {
            XCTAssertEqual(MFSStateDecoder.state(usesFTBL: false,
                                                 presentFileIndices: [index]),
                           .initialized, "index \(index)")
        }
    }

    func testConfiguredWhenOnlyFaultOrBackupPresent() {
        // {7,9} alone (faults log / backup) means the volume is provisioned but
        // carries none of the Initialized reserved files yet.
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: false,
                                             presentFileIndices: [7]),
                       .configured)
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: false,
                                             presentFileIndices: [9]),
                       .configured)
    }

    func testInitializedWinsOverConfigured() {
        // Upstream checks the Initialized set first; a volume with both sorts
        // as Initialized.
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: false,
                                             presentFileIndices: [8, 9]),
                       .initialized)
    }

    func testEmptyVolumeStaysUnconfigured() {
        // A decodable legacy volume with no matching reserved file — no state.
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: false,
                                             presentFileIndices: []),
                       .unconfigured)
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: false,
                                             presentFileIndices: [10]),
                       .unconfigured)
    }

    func testFTBLVolumeAlwaysUnconfigured() {
        // A vfs_starts_at_0 / FileTable.dat-named volume never maps its raw FAT
        // indices to the legacy semantic set — the row stays Unconfigured.
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: true,
                                             presentFileIndices: [8]),
                       .unconfigured)
        XCTAssertEqual(MFSStateDecoder.state(usesFTBL: true,
                                             presentFileIndices: [7, 9]),
                       .unconfigured)
    }
}

