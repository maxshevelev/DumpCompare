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
}
