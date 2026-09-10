import XCTest
import Foundation
@testable import MEFirmware

/// `OEMDetector` — row-14 "OEM Configuration" bool
/// (`oem_signed or oemp_found or utok_found`, MEA.py 13725). Affirmative,
/// fixture-only: each test drives one fact to one side with a synthetic
/// partition/module inventory and the exact region bytes that fact reads, so a
/// false "Yes" from a misunderstood placeholder is impossible to assert wrongly.
final class OEMDetectorTests: XCTestCase {
    // MARK: - Fixture builders

    private func fpt(_ parts: [FPTParser.Partition]) -> FPTParser.Result {
        FPTParser.Result(headerVersion: 0x20, resolvedVersion: 0x20,
                         fptStart: 0, fitMajor: 0, fitMinor: 0, fitHotfix: 0,
                         fitBuild: 0, partitions: parts, cseLayout: nil)
    }

    private func partition(_ name: String, offset: Int, size: Int) -> FPTParser.Partition {
        FPTParser.Partition(name: name, offset: offset, size: size, flags: 0,
                            empty: false)
    }

    private func boot(_ entries: [BPDTPartition]) -> BPDT {
        BPDT(offset: 0x1000, partitionName: "Boot 1", version: 2,
             redundancy: true, checksumValid: true,
             fitMajor: nil, fitMinor: nil, fitHotfix: nil, fitBuild: nil,
             entries: entries)
    }

    /// The Intel "OEM" placeholder key's opening 16 bytes (bccb_pat MEA.py
    /// 11009): `\xCB\xBC.{9}\x00$MN2` — VEN_ID 0xBCCB little-endian, nine
    /// wildcard bytes, a NUL, then the `$MN2` recovery trailer.
    private func bccbPlaceholder() -> Data {
        var d = Data(repeating: 0x00, count: 16)
        d[0] = 0xCB; d[1] = 0xBC        // VEN_ID 0xBCCB LE
        d[11] = 0x00                    // the NUL after the nine wildcards
        d.replaceSubrange(12..<16, with: Data("$MN2".utf8))
        return d
    }

    /// A 0x00-filled region (not erased, so nothing trips the all-FF empty head
    /// guard), large enough for any fixture offset.
    private func liveRegion(_ size: Int = 0x4000) -> Data {
        Data(repeating: 0x00, count: size)
    }

    // MARK: - oemp_found / utok_found (region $FPT inventory, 11786–11790)

    /// A non-empty UTOK partition in the region's own `$FPT` → Yes.
    func testUTOKInFPTInventoryIsOEM() {
        let region = liveRegion()
        let result = OEMDetector.oemCustomized(
            fpt: fpt([partition("UTOK", offset: 0x1000, size: 0x100)]),
            bootPartitions: nil, codePartition: nil,
            in: region, baseOffset: 0)
        XCTAssertTrue(result)
    }

    /// A non-empty OEMP partition whose body is *not* the BCCB placeholder →
    /// Yes; an empty OEMP is not evidence.
    func testRealOEMPInFPTInventoryIsOEM() {
        let result = OEMDetector.oemCustomized(
            fpt: fpt([partition("OEMP", offset: 0x1000, size: 0x100)]),
            bootPartitions: nil, codePartition: nil,
            in: liveRegion(), baseOffset: 0)
        XCTAssertTrue(result)
    }

    /// An OEMP partition that opens with the BCCB placeholder is Intel's stock
    /// layout, not an OEM story → stays false (the placeholder is rejected).
    func testOEMPPlaceholderInFPTInventoryIsNotOEM() {
        var region = liveRegion()
        region.replaceSubrange(0x1000..<0x1010, with: bccbPlaceholder())
        let result = OEMDetector.oemCustomized(
            fpt: fpt([partition("OEMP", offset: 0x1000, size: 0x100)]),
            bootPartitions: nil, codePartition: nil,
            in: region, baseOffset: 0)
        XCTAssertFalse(result)
    }

    /// A UTOK partition whose head is entirely erased (0xFF fill) reads as no
    /// populated partition → false, exactly like upstream's full-window compare.
    func testErasedUTOKHeadIsNotOEM() {
        // Region 0x1000..<0x1010 left as the buffer's 0xFF fill.
        let result = OEMDetector.oemCustomized(
            fpt: fpt([partition("UTOK", offset: 0x1000, size: 0x100)]),
            bootPartitions: nil, codePartition: nil,
            in: Data(repeating: 0xFF, count: 0x4000), baseOffset: 0)
        XCTAssertFalse(result)
    }

    // MARK: - oemp_found / utok_found (IFWI boot-slot BPDT inventory, 12129–12133)

    /// A UTOK entry inside a whole-flash Boot BPDT (absolute offset, normalised
    /// by `baseOffset`) → Yes. Covers the second upstream scan site.
    func testUTOKInBootBPDTInventoryIsOEM() {
        let result = OEMDetector.oemCustomized(
            fpt: nil,
            bootPartitions: [boot([BPDTPartition(id: 0, name: "UTOK", type: 0,
                                                 offset: 0x1000 + 0x1000,
                                                 size: 0x100, empty: false)])],
            codePartition: nil,
            in: liveRegion(), baseOffset: 0x1000)
        XCTAssertTrue(result)
    }

    // MARK: - oem_signed (the oem.key $CPD module, 6015–6016)

    /// A code partition whose `oem.key` module body is real (no placeholder) →
    /// Yes. `module.offset` counts from the CPD header base, so
    /// `cp.offset - baseOffset + module.offset` is the region-relative body.
    func testRealOemKeyModuleIsSigned() {
        let module = CPDModule(id: 0, name: "oem.key", offset: 0x800,
                               isHuffman: false, size: 0x100)
        let cp = CodePartition(name: "FTPR", offset: 0x2000, headerVersion: 1,
                               headerLength: 0x10, entryCount: 1,
                               checksumValid: true, modules: [module])
        let result = OEMDetector.oemCustomized(
            fpt: nil, bootPartitions: nil, codePartition: cp,
            in: liveRegion(), baseOffset: 0x1000)
        XCTAssertTrue(result)   // body at 0x2000−0x1000+0x800 = 0x1800, real
    }

    /// An `oem.key` whose body opens with the BCCB placeholder is Intel's stock
    /// key, not a signing key → false, never a placeholder-induced "Yes".
    func testPlaceholderOemKeyModuleIsNotSigned() {
        var region = liveRegion()
        region.replaceSubrange(0x1800..<0x1810, with: bccbPlaceholder())
        let module = CPDModule(id: 0, name: "oem.key", offset: 0x800,
                               isHuffman: false, size: 0x100)
        let cp = CodePartition(name: "FTPR", offset: 0x2000, headerVersion: 1,
                               headerLength: 0x10, entryCount: 1,
                               checksumValid: true, modules: [module])
        let result = OEMDetector.oemCustomized(
            fpt: nil, bootPartitions: nil, codePartition: cp,
            in: region, baseOffset: 0x1000)
        XCTAssertFalse(result)
    }

    // MARK: - Stock

    /// A plain stock image — no OEM partitions in either inventory, no oem.key
    /// module — reads false (upstream's default False).
    func testStockWithNoOEMFactsIsNotOEM() {
        let result = OEMDetector.oemCustomized(
            fpt: fpt([]), bootPartitions: [], codePartition: nil,
            in: liveRegion(), baseOffset: 0)
        XCTAssertFalse(result)
    }

    /// Even a populated `oem.key` needs a body inside the region: an offset past
    /// the end is not a signing key (entry_empty), so no false "Yes".
    func testOemKeyOutsideRegionIsNotSigned() {
        let module = CPDModule(id: 0, name: "oem.key", offset: 0x8000,
                               isHuffman: false, size: 0x100)
        let cp = CodePartition(name: "FTPR", offset: 0x2000, headerVersion: 1,
                               headerLength: 0x10, entryCount: 1,
                               checksumValid: true, modules: [module])
        let result = OEMDetector.oemCustomized(
            fpt: nil, bootPartitions: nil, codePartition: cp,
            in: liveRegion(), baseOffset: 0x1000)
        XCTAssertFalse(result)
    }
}
