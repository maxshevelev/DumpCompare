import XCTest
import Foundation
@testable import MEFirmware

/// Builds a synthetic `$CPD` directory (header + entries) mirroring
/// `CPD_Header_R1` (0x10) / `CPD_Header_R2` (0x14) + `CPD_Entry` (0x18).
/// R1's checksum byte at +0x0B is computed as Checksum-8 over header+entries
/// with the field zeroed; R2's u32 at +0x10 as CRC-32 over the same span with
/// the CRC field zeroed (`cpd_chk`, both branches).
enum CPDFixture {
    static func setUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data[offset + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// Per-module `OffsetCPD`/`Size` override. When given, each entry's offset
    /// (bits 0–24 of OffsetAttrib) and uncompressed Size are written instead of
    /// left zeroed — an analyzer test that places real module content after the
    /// directory (the manifest + its extension chain) needs them.
    typealias ModuleLayout = (offset: UInt32, size: UInt32)

    static func make(name: String, headerVersion: Int = 1,
                     moduleNames: [String] = ["$MN2"],
                     moduleLayout: [ModuleLayout]? = nil) -> Data {
        let headerLength = headerVersion == 2 ? 0x14 : 0x10
        var data = Data(repeating: 0, count: headerLength + moduleNames.count * 0x18)
        data.replaceSubrange(0..<4, with: Data("$CPD".utf8))
        setUInt32(UInt32(moduleNames.count), in: &data, at: 0x04)  // NumModules
        data[0x08] = UInt8(headerVersion)                          // HeaderVersion
        data[0x09] = 1                                             // EntryVersion
        data[0x0A] = UInt8(headerLength)                           // HeaderLength
        for (index, byte) in name.utf8.prefix(4).enumerated() {    // PartitionName
            data[0x0C + index] = byte
        }
        for (moduleIndex, module) in moduleNames.enumerated() {
            let entry = headerLength + moduleIndex * 0x18
            for (index, byte) in module.utf8.prefix(12).enumerated() {
                data[entry + index] = byte                         // CPD_Entry.Name
            }
            if let moduleLayout, moduleIndex < moduleLayout.count {
                setUInt32(moduleLayout[moduleIndex].offset, in: &data, at: entry + 0x0C)  // OffsetCPD
                setUInt32(moduleLayout[moduleIndex].size, in: &data, at: entry + 0x10)    // Size
            }
        }
        if headerVersion == 1 {
            var sum = 0
            for index in 0..<data.count where index != 0x0B {
                sum += Int(data[index])
            }
            data[0x0B] = UInt8((0x100 - (sum & 0xFF)) & 0xFF)      // Checksum-8
        } else {
            // CRC-32 stored at +0x10, computed over the whole directory with the
            // 4-byte CRC field zeroed (cpd_chk R2 branch).
            setUInt32(CRC32.crc32(data), in: &data, at: 0x10)
        }
        return data
    }
}

final class CPDParserTests: XCTestCase {
    func testDecodesR1Header() throws {
        let data = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2", "rbe"])
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))

        XCTAssertEqual(header.base, 0)
        XCTAssertEqual(header.numModules, 2)
        XCTAssertEqual(header.headerVersion, 1)
        XCTAssertEqual(header.entryVersion, 1)
        XCTAssertEqual(header.headerLength, 0x10)
        XCTAssertEqual(header.partitionName, "FTPR")
        XCTAssertNotNil(header.checksumField)
    }

    func testDecodesR2HeaderWithCRCField() throws {
        let data = CPDFixture.make(name: "RBEP", headerVersion: 2)
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))

        XCTAssertEqual(header.headerVersion, 2)
        XCTAssertEqual(header.headerLength, 0x14)
        XCTAssertEqual(header.partitionName, "RBEP")
        XCTAssertNotEqual(header.checksumField, 0)              // fixture stores a real CRC-32
        XCTAssertEqual(CPDParser.checksumValid(header, in: data), true)
    }

    func testRejectsNonCPDAndMalformedHeaders() {
        XCTAssertNil(CPDParser.decodeHeader(in: Data(repeating: 0xFF, count: 0x30), at: 0))
        // Tag present but a zero byte count high-word / wrong version.
        var bogus = Data(repeating: 0, count: 0x30)
        bogus.replaceSubrange(0..<4, with: Data("$CPD".utf8))
        XCTAssertNil(CPDParser.decodeHeader(in: bogus, at: 0))  // NumModules 0 is allowed, but…
        bogus[0x08] = 9                                          // …bad version is not
        XCTAssertNil(CPDParser.decodeHeader(in: bogus, at: 0))
    }

    func testReadsEntries() throws {
        let data = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2"])
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))
        let entries = CPDParser.entries(of: header, in: data, cpdBase: 0)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "$MN2")
        XCTAssertEqual(entries[0].offset, 0)         // OffsetCPD 0 in the fixture
        XCTAssertFalse(entries[0].isHuffman)
    }

    func testR1ChecksumValidation() throws {
        let data = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2", "rbe"])
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))
        XCTAssertEqual(CPDParser.checksumValid(header, in: data), true)

        // Corrupting any covered byte makes the stored checksum fail.
        var corrupted = data
        corrupted[0x10] ^= 0xFF                    // an entry-name byte
        let badHeader = try XCTUnwrap(CPDParser.decodeHeader(in: corrupted, at: 0))
        XCTAssertEqual(CPDParser.checksumValid(badHeader, in: corrupted), false)
    }

    func testR2ChecksumValidation() throws {
        let data = CPDFixture.make(name: "RBEP", headerVersion: 2)
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))
        XCTAssertEqual(CPDParser.checksumValid(header, in: data), true)

        // Corrupting any covered byte (the CRC field is the zeroed part) makes it fail.
        var corrupted = data
        corrupted[0x0C] ^= 0xFF                    // a PartitionName byte
        let badHeader = try XCTUnwrap(CPDParser.decodeHeader(in: corrupted, at: 0))
        XCTAssertEqual(CPDParser.checksumValid(badHeader, in: corrupted), false)
    }

    func testTrailingEmptyEntryProbe() throws {
        // A directory whose real span is followed by two all-zero 0x18 slots — the
        // shape cpd_entry_num_fix grows the count over. The probe reports them but
        // the decoded module list stays at the declared count.
        var data = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2", "rbe"])
        data.append(Data(repeating: 0, count: 2 * 0x18))
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))
        XCTAssertEqual(CPDParser.trailingEmptyEntryCount(of: header, in: data), 2)
        XCTAssertEqual(CPDParser.entries(of: header, in: data, cpdBase: 0).count, 2)
    }

    func testModuleContentEnd() throws {
        // Layout mimics the analyzer integration test: entries at offsets 0x10 and
        // 0x28 of sizes 0x30 and 0x20 → content spans base+0x40 .. base+0x48.
        let layout = [(offset: UInt32(0x10), size: UInt32(0x30)),
                      (offset: UInt32(0x28), size: UInt32(0x20))]
        let data = CPDFixture.make(name: "FTPR", moduleNames: ["a", "b"], moduleLayout: layout)
        let header = try XCTUnwrap(CPDParser.decodeHeader(in: data, at: 0))
        let entries = CPDParser.entries(of: header, in: data, cpdBase: 0)
        XCTAssertEqual(CPDParser.moduleContentEnd(of: header, entries: entries),
                       header.base + 0x28 + 0x20)
    }

    func testFindPrecedingCPDFindsNearestInWindow() throws {
        let one = CPDFixture.make(name: "FTPR")              // 0x28 bytes each
        var data = Data()
        data.append(one)                                    // cpd @ 0x00 (FTPR)
        data.append(CPDFixture.make(name: "RBEP"))          // cpd @ 0x28 (RBEP decoy)
        data.append(one)                                    // cpd @ 0x50 (FTPR, nearest)
        // Probe base just past the last header: its tag must fit fully inside
        // the scan window for it to be found.
        let found = try XCTUnwrap(CPDParser.findPrecedingCPD(in: data,
                                                             before: 2 * one.count + one.count))
        XCTAssertEqual(found.offset, 2 * one.count)
        XCTAssertEqual(found.header.partitionName, "FTPR")
    }

    func testFindPrecedingCPDReturnsNilOutsideWindow() {
        // CPD at 0; a probe base more than 0x201D bytes later cannot see it.
        let data = CPDFixture.make(name: "FTPR")
        let far = data.count + 0x3000
        var region = data
        region.append(Data(repeating: 0, count: 0x3000))
        XCTAssertNil(CPDParser.findPrecedingCPD(in: region, before: far))
    }
}
