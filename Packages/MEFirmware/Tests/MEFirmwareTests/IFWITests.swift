import XCTest
import Foundation
@testable import MEFirmware

/// Synthetic coverage for the IFWI/CSE-Layout-Table detection and the Flash
/// Descriptor ME-region read that anchor the FPT `fpt_start` fix — built from
/// the layouts confirmed on the three real whole-flash oracles (LT16 present on
/// CSME 12, LT17 present on CSME 15, neither on pre-IFWI CSME 11).
final class IFWITests: XCTestCase {
    private func le(_ value: UInt32, _ data: inout Data, at off: Int) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data[off + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// A 0x2000 erased buffer with a CSE Layout Table at 0 whose Data partition
    /// starts at 0x1000 (`$FPT`) and Boot Partition 1 at 0x1100 (BPDT sig).
    private func table16Buffer() -> Data {
        var d = Data(repeating: 0xFF, count: 0x2000)
        le(0x1000, &d, at: 0x10)               // DataOffset
        le(0x1100, &d, at: 0x18)               // BP1Offset
        d.replaceSubrange(0x1000..<0x1004, with: Data("$FPT".utf8))
        d.replaceSubrange(0x1100..<0x1104, with: Data([0xAA, 0x55, 0x00, 0x00]))
        return d
    }

    func testDetectsIFWI16Table() {
        XCTAssertEqual(IFWI.detectCseLayoutTable(in: table16Buffer(), at: 0), 0x16)
    }

    func testDetectsIFWI17Table() {
        var d = table16Buffer()
        d[0x10] = 0x40                          // LT17 Size (u16), not a DataOffset
        d[0x11] = 0x00
        le(0x1000, &d, at: 0x18)                // LT17 DataOffset @0x18
        le(0x1100, &d, at: 0x20)                // LT17 BP1Offset @0x20
        // LT16 reading of the same bytes must fail first (DataOffset would be
        // 0x40 → not `$FPT`), so detection must land on the 1.7 table.
        XCTAssertEqual(IFWI.detectCseLayoutTable(in: d, at: 0), 0x17)
    }

    func testNoTableWhenPaddingNotErased() {
        var d = table16Buffer()
        d[0x48] = 0x00                          // a real byte in the "erased" pad
        XCTAssertNil(IFWI.detectCseLayoutTable(in: d, at: 0))
    }

    func testBPDTHeaderIsNotATable() {
        var d = Data(repeating: 0xFF, count: 0x1000)
        d.replaceSubrange(0..<4, with: Data([0xAA, 0x55, 0x00, 0x00]))
        XCTAssertNil(IFWI.detectCseLayoutTable(in: d, at: 0))
    }

    func testMEBaseFromFlashDescriptor() {
        var d = Data(repeating: 0xFF, count: 0x100000)
        for i in 0..<d.count { d[i] = 0x00 }    // blank
        d.replaceSubrange(0x10..<0x14, with: Data([0x5A, 0xA5, 0xF0, 0x0F]))  // on-image sig
        d[0x14] = 0x03
        for i in 0xC0..<0xD0 { d[i] = 0xFF }    // erased run the FD pattern needs
        d[0x48] = 0x10; d[0x49] = 0x00          // FLREG2 base = 0x10 → 0x10000
        d[0x4A] = 0x12; d[0x4B] = 0x00          // limit = 0x12 → (0x12+1−0x10)<<12
        let region = try! XCTUnwrap(FlashDescriptor.meRegion(in: d))
        XCTAssertEqual(region.base, 0x10000)
        XCTAssertEqual(region.size, 0x3000)
    }

    func testNoMEBaseWithoutDescriptor() {
        XCTAssertNil(FlashDescriptor.meRegion(in: Data(repeating: 0xFF, count: 0x1000)))
    }

    // ——— Layout Table inventory decode ———

    /// A 0x2000 buffer whose 0x0000..0x1000 is the LT header (FF pad after the
    /// struct), Data partition at 0x1000 carrying `$FPT`, Boot Partition 1 at
    /// 0x1200 carrying a BPDT signature; Boot 2–5 offset/size stay 0xFFFFFFFF
    /// (erased FF fill) → NA → empty.
    private func inventory16Buffer() -> Data {
        var d = Data(repeating: 0xFF, count: 0x2000)
        le(0x1000, &d, at: 0x10)               // DataOffset
        le(0x100, &d, at: 0x14)                // DataSize
        le(0x1200, &d, at: 0x18)               // BP1Offset
        le(0x80, &d, at: 0x1C)                 // BP1Size
        d.replaceSubrange(0x1000..<0x1004, with: Data("$FPT".utf8))
        d.replaceSubrange(0x1200..<0x1204, with: Data([0xAA, 0x55, 0x00, 0x00]))
        return d
    }

    func testDecodesIFWI16Inventory() {
        let layout = try! XCTUnwrap(IFWI.layoutTable(in: inventory16Buffer(), at: 0))
        XCTAssertEqual(layout.version, 0x16)
        XCTAssertEqual(layout.base, 0)
        XCTAssertEqual(layout.redundancy, false)   // 1.6 has no redundancy flag
        XCTAssertNil(layout.checksumValid)         // 1.6 stores no comparable CRC

        let data = layout.slots[0]
        XCTAssertEqual(data.name, "Data")
        XCTAssertEqual(data.offset, 0x1000)        // base + raw offset
        XCTAssertEqual(data.size, 0x100)
        XCTAssertEqual(data.empty, false)

        XCTAssertEqual(layout.slots[1].name, "Boot 1")
        XCTAssertEqual(layout.slots[1].offset, 0x1200)
        XCTAssertEqual(layout.slots[1].empty, false)

        // Boot 2–5: NA offset/size (0xFFFFFFFF) → still listed, marked empty.
        XCTAssertEqual(layout.slots.map(\.name),
                       ["Data", "Boot 1", "Boot 2", "Boot 3", "Boot 4", "Boot 5"])
        for slot in layout.slots[2...] { XCTAssertTrue(slot.empty) }
    }

    func testDecodesIFWI16PartitionOnRegionOffset() {
        // The same table placed 0x1000 into a region (a bare ME region whose LT
        // sits at its own start would be 0; this just pins the offset math).
        var d = Data(repeating: 0xFF, count: 0x4000)
        d.replaceSubrange(0x1000..<0x3000, with: inventory16Buffer())
        let layout = try! XCTUnwrap(IFWI.layoutTable(in: d, at: 0x1000))
        XCTAssertEqual(layout.base, 0x1000)
        XCTAssertEqual(layout.slots[0].offset, 0x1000 + 0x1000)
        XCTAssertEqual(layout.slots[0].empty, false)
    }

    func testNoLayoutTableWhenNonePresent() {
        XCTAssertNil(IFWI.layoutTable(in: Data(repeating: 0xFF, count: 0x2000), at: 0))
        XCTAssertNil(IFWI.layoutTable(in: Data(repeating: 0x00, count: 0x2000), at: 0))
    }

    /// An IFWI 1.7 table (MEA.py 556): Size 0x48 (w/ ELog), CSE Redundancy set,
    /// real CRC-32 over Size..Flags+Reserved + zeroed CRC word + DataOffset..
    /// 0x10+Size, stored at 0x14. Data @0x1000, BP1 @0x1200, Temp/ELog NA.
    private func inventory17Buffer(corruptChecksum: Bool = false) -> Data {
        var d = Data(repeating: 0xFF, count: 0x2000)
        // Size u16 @0x10
        d[0x10] = 0x48; d[0x11] = 0x00
        d[0x12] = 0x01                                   // Flags: bit0 Redundancy
        d[0x13] = 0x00                                   // Reserved
        le(0x1000, &d, at: 0x18)                         // DataOffset
        le(0x100, &d, at: 0x1C)                          // DataSize
        le(0x1200, &d, at: 0x20)                         // BP1Offset
        le(0x80, &d, at: 0x24)                           // BP1Size
        // BP2–5, Temp & ELog offset/size stay 0xFFFFFFFF (FF fill) → NA → empty.
        d.replaceSubrange(0x1000..<0x1004, with: Data("$FPT".utf8))
        d.replaceSubrange(0x1200..<0x1204, with: Data([0xAA, 0x55, 0x00, 0x00]))
        // CRC window = [0x10:0x14] + 4 zero (CRC word) + [0x18 : 0x10+Size].
        var window = d.subdata(in: 0x10..<0x14)
        window.append(Data([0, 0, 0, 0]))
        window.append(d.subdata(in: 0x18..<(0x10 + 0x48)))
        var stored = CRC32.crc32(window)
        if corruptChecksum { stored ^= 0x0000_0001 }
        le(stored, &d, at: 0x14)
        return d
    }

    func testDecodesIFWI17InventoryWithChecksum() {
        let layout = try! XCTUnwrap(IFWI.layoutTable(in: inventory17Buffer(), at: 0))
        XCTAssertEqual(layout.version, 0x17)
        XCTAssertEqual(layout.redundancy, true)
        XCTAssertEqual(layout.checksumValid, true)

        // Data, Boot 1–5, Temp, ELog (Size 0x48 → ELog declared).
        XCTAssertEqual(layout.slots.map(\.name),
                       ["Data", "Boot 1", "Boot 2", "Boot 3", "Boot 4", "Boot 5",
                        "Temp", "ELog"])
        XCTAssertEqual(layout.slots[0].empty, false)
        XCTAssertEqual(layout.slots[1].empty, false)
        XCTAssertEqual(layout.slots[6].name, "Temp")
        XCTAssertTrue(layout.slots[6].empty)             // TempPages NA
        XCTAssertTrue(layout.slots[7].empty)             // ELog NA
    }

    func testReportsInvalidIFWI17Checksum() {
        let layout = try! XCTUnwrap(IFWI.layoutTable(in: inventory17Buffer(corruptChecksum: true), at: 0))
        XCTAssertEqual(layout.version, 0x17)
        XCTAssertEqual(layout.checksumValid, false)
    }

    // ——— Boot Partition Descriptor Table decode ———

    /// A 0x4000 erased buffer holding an IFWI 1.7 BPDT at 0 (`BPDT_Header_2`):
    /// 3 entries — RBEP @0x1000, ISIF @0x2000 (real content), PCHC NA/empty —
    /// a real CRC-32 over header+entries with the stored checksum zeroed, and
    /// the redundancy bit set. Mirrors the 1.bin Boot1 shape (FIT 15.0.30).
    private func bpdt17Buffer(corruptChecksum: Bool = false) -> Data {
        var d = Data(repeating: 0xFF, count: 0x4000)
        d.replaceSubrange(0..<4, with: Data([0xAA, 0x55, 0x00, 0x00]))
        d[0x04] = 0x03; d[0x05] = 0x00          // DescCount = 3
        d[0x06] = 0x02                          // BPDT version 2 (IFWI 1.7)
        d[0x07] = 0x01                          // BPDTConfig: bit0 redundancy
        le(0, &d, at: 0x0C)                     // IFWIVersion
        le(15, &d, at: 0x10)                    // FitMajor
        le(0, &d, at: 0x12)                     // FitMinor
        le(0x1E, &d, at: 0x14)                  // FitHotfix
        le(0x06B4, &d, at: 0x16)                // FitBuild
        // Entries at 0x18, stride 0xC: le() writes the 4-byte type+flags word.
        le(1, &d, at: 0x18); le(0x1000, &d, at: 0x1C); le(0x100, &d, at: 0x20)   // RBEP
        le(33, &d, at: 0x24); le(0x2000, &d, at: 0x28); le(0x100, &d, at: 0x2C)  // ISIF
        le(32, &d, at: 0x30); le(0, &d, at: 0x34); le(0, &d, at: 0x38)            // PCHC NA→empty
        d.replaceSubrange(0x1000..<0x1008, with: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]))
        d.replaceSubrange(0x2000..<0x2008, with: Data([0xAA, 0x55, 0x00, 0x00, 1, 0, 0, 0]))
        // CRC window: [0x04:0x08] + 4 zero + [0x0C : 0x18+count*0xC].
        let end = 0x18 + 3 * 0x0C
        var window = d.subdata(in: 0x04..<0x08)
        window.append(Data([0, 0, 0, 0]))
        window.append(d.subdata(in: 0x0C..<end))
        var stored = CRC32.crc32(window)
        if corruptChecksum { stored ^= 0x0000_0001 }
        le(stored, &d, at: 0x08)
        return d
    }

    /// An IFWI 1.6/2.0 BPDT at 0 (`BPDT_Header_1`): 2 entries — FTPR @0x1000
    /// (real content), RBEP NA/empty. Mirrors the DATMAAMBAC0 Boot1 shape.
    private func bpdt16Buffer() -> Data {
        var d = Data(repeating: 0xFF, count: 0x4000)
        d.replaceSubrange(0..<4, with: Data([0xAA, 0x55, 0x00, 0x00]))
        d[0x04] = 0x02; d[0x05] = 0x00          // DescCount = 2
        d[0x06] = 0x01; d[0x07] = 0x00          // BPDT version 1 (u16 low byte)
        le(12, &d, at: 0x10)                    // FitMajor
        le(0, &d, at: 0x12)                     // FitMinor
        le(3, &d, at: 0x14)                     // FitHotfix
        le(1091, &d, at: 0x16)                  // FitBuild
        le(2, &d, at: 0x18); le(0x1000, &d, at: 0x1C); le(0x100, &d, at: 0x20)   // FTPR
        le(1, &d, at: 0x24); le(0, &d, at: 0x28); le(0, &d, at: 0x2C)             // RBEP empty
        d.replaceSubrange(0x1000..<0x1008, with: Data(repeating: 0x00, count: 8))
        return d
    }

    func testFirstBpdtFindsHeader() {
        var d = Data(repeating: 0xFF, count: 0x4000)
        d.replaceSubrange(0x500..<(0x500 + 0x3C), with: bpdt17Buffer().prefix(0x3C))
        XCTAssertEqual(IFWI.firstBpdt(in: d, lo: 0, hi: 0x1000), 0x500)
        XCTAssertNil(IFWI.firstBpdt(in: Data(repeating: 0xFF, count: 0x1000), lo: 0, hi: 0x1000))
    }

    func testDecodesIFWI17BPDT() {
        let info = try! XCTUnwrap(IFWI.bpdtTable(in: bpdt17Buffer(), at: 0, partitionName: "Boot 1"))
        XCTAssertEqual(info.partitionName, "Boot 1")
        XCTAssertEqual(info.version, 2)                 // IFWI 1.7
        XCTAssertEqual(info.redundancy, true)           // BPDTConfig bit 0
        XCTAssertEqual(info.checksumValid, true)        // real CRC-32 over the table
        // The header's FIT words (15.0.30.1716) survive the decode.
        XCTAssertEqual(info.fitMajor, 15)
        XCTAssertEqual(info.fitMinor, 0)
        XCTAssertEqual(info.fitHotfix, 0x1E)
        XCTAssertEqual(info.fitBuild, 0x06B4)
        XCTAssertEqual(info.slots.map(\.name), ["RBEP", "ISIF", "PCHC"])
        XCTAssertEqual(info.slots[0].type, 1)
        XCTAssertEqual(info.slots[0].offset, 0x1000)    // base + raw offset
        XCTAssertEqual(info.slots[0].size, 0x100)
        XCTAssertEqual(info.slots[0].empty, false)
        XCTAssertEqual(info.slots[1].empty, false)
        XCTAssertEqual(info.slots[2].empty, true)       // NA offset/size
    }

    func testReportsInvalidIFWI17BPDTChecksum() {
        let info = try! XCTUnwrap(IFWI.bpdtTable(in: bpdt17Buffer(corruptChecksum: true), at: 0,
                                                 partitionName: "Boot 1"))
        XCTAssertEqual(info.checksumValid, false)
    }

    func testDecodesIFWI16BPDT() {
        let info = try! XCTUnwrap(IFWI.bpdtTable(in: bpdt16Buffer(), at: 0, partitionName: "Boot 1"))
        XCTAssertEqual(info.version, 1)                 // IFWI 1.6 & 2.0
        XCTAssertEqual(info.redundancy, false)          // no config byte on v1
        XCTAssertNil(info.checksumValid)                // v1 stores an XOR value
        // The header's FIT words (12.0.3.1091, the DATMAAMBAC0 oracle) survive.
        XCTAssertEqual(info.fitMajor, 12)
        XCTAssertEqual(info.fitMinor, 0)
        XCTAssertEqual(info.fitHotfix, 3)
        XCTAssertEqual(info.fitBuild, 1091)
        XCTAssertEqual(info.slots.map(\.name), ["FTPR", "RBEP"])
        XCTAssertEqual(info.slots[0].offset, 0x1000)
        XCTAssertEqual(info.slots[0].empty, false)
        XCTAssertEqual(info.slots[1].empty, true)
    }

    /// A valid BPDT whose FIT words are erased back to 0xFF reads the no-FIT
    /// marker — the whole quartet decodes to nil, never a bogus 65535.
    func testNoFITWhenHeaderFITErased() {
        var d = bpdt16Buffer()
        for i in 0x10..<0x18 { d[i] = 0xFF }            // erase the FIT words
        let info = try! XCTUnwrap(IFWI.bpdtTable(in: d, at: 0, partitionName: "Boot 1"))
        XCTAssertNil(info.fitMajor)
        XCTAssertNil(info.fitMinor)
        XCTAssertNil(info.fitHotfix)
        XCTAssertNil(info.fitBuild)
        XCTAssertEqual(info.version, 1)                 // the rest still decodes
    }

    func testNoBPDTOnErasedOrTruncated() {
        XCTAssertNil(IFWI.bpdtTable(in: Data(repeating: 0xFF, count: 0x4000), at: 0,
                                    partitionName: "Boot 1"))
        // An entry table that overruns the region end is rejected.
        var d = bpdt16Buffer()
        XCTAssertNotNil(IFWI.bpdtTable(in: d, at: 0, partitionName: "Boot 1"))
        d[0x04] = 0xFF                                  // absurd DescCount → table runs past end
        d[0x05] = 0xFF
        XCTAssertNil(IFWI.bpdtTable(in: d, at: 0, partitionName: "Boot 1"))
    }
}
