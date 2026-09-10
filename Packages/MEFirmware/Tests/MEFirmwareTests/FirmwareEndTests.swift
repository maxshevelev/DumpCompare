import XCTest
import Foundation
@testable import MEFirmware

/// `FirmwareEndCalculator` — row 18's Size (upstream `eng_fw_end`): how far the
/// firmware reaches from its `$FPT`, which is not how big the buffer around it
/// is. The inputs are built straight on the parser structs, the way
/// `ExtensionHoistTests` builds extension payloads; the CSME-12 case is the
/// real oracle's own numbers.
final class FirmwareEndTests: XCTestCase {
    private func part(_ name: String, _ offset: Int, _ size: Int,
                      empty: Bool = false) -> FPTParser.Partition {
        FPTParser.Partition(name: name, offset: offset, size: size,
                            flags: 0, empty: empty)
    }

    private func slot(_ name: String, _ offset: Int, _ size: Int,
                      empty: Bool = false) -> IFWI.LayoutSlot {
        IFWI.LayoutSlot(name: name, offset: offset, size: size, empty: empty)
    }

    private func layout(base: Int, _ slots: [IFWI.LayoutSlot]) -> IFWI.LayoutInfo {
        IFWI.LayoutInfo(base: base, version: 0x16, redundancy: false,
                        checksumValid: nil, slots: slots)
    }

    private func size(_ partitions: [FPTParser.Partition],
                      fptStart: Int,
                      in region: Data = Data(repeating: 0xFF, count: 0x8000),
                      layout: IFWI.LayoutInfo? = nil,
                      hasFlashDescriptor: Bool = true,
                      ignores4KAlignment: Bool = false) -> Int? {
        FirmwareEndCalculator.firmwareSize(
            in: region, partitions: partitions, fptStart: fptStart,
            cseLayout: layout, hasFlashDescriptor: hasFlashDescriptor,
            ignores4KAlignment: ignores4KAlignment)
    }

    // MARK: - The `$FPT` leg

    /// The end that counts is the end of the partition that *starts* last, not
    /// the greatest end in the table — a partition placed earlier may well
    /// reach further, and upstream still measures from the last one.
    func testTheLastStartingPartitionDecidesTheEnd() {
        let measured = size([
            part("FTPR", 0x1000, 0x5000),   // ends 0x6000 — further than the last
            part("MFS", 0x2000, 0x1000),    // starts last, ends 0x3000
        ], fptStart: 0x1000)
        XCTAssertEqual(measured, 0x2000, "0x3000 − 0x1000, already 4K aligned")
    }

    /// An unaligned end is padded to the next 4 KiB, the way the firmware
    /// itself is laid out on flash.
    func testAnUnalignedEndIsRoundedUp() {
        XCTAssertEqual(size([part("FTPR", 0x1000, 0x2800)], fptStart: 0x1000),
                       0x3000, "0x2800 rounds up to 0x3000")
    }

    /// CSME 16 stopped padding: Intel's own MFIT-built images are unaligned,
    /// so rounding one up would overstate the firmware.
    func testCSME16KeepsTheUnalignedEnd() {
        XCTAssertEqual(size([part("FTPR", 0x1000, 0x2800)], fptStart: 0x1000,
                            ignores4KAlignment: true),
                       0x2800)
    }

    /// A NA offset says nothing about where the firmware ends, so the entry
    /// carrying it never becomes the last one.
    func testAnErasedEntryDoesNotDecideTheEnd() {
        XCTAssertEqual(size([
            part("FTPR", 0x1000, 0x2000),
            part("", 0xFFFF_FFFF, 0xFFFF_FFFF, empty: true),
        ], fptStart: 0x1000), 0x2000)
    }

    /// An ME 2–6 table leaves the last partition's size out, and the end is
    /// then only knowable by walking that partition's submodules — a leg this
    /// engine does not port, so it says nothing rather than 4 GiB.
    func testALastPartitionWithoutASizeIsNotGuessed() {
        XCTAssertNil(size([part("FTPR", 0x1000, 0)], fptStart: 0x1000))
        XCTAssertNil(size([], fptStart: 0x1000), "and an empty table measures nothing")
    }

    /// An uncharted partition can start up to 4 KiB past the last charted one.
    /// On an image with neither a flash descriptor nor a Layout Table — an
    /// extracted region — upstream looks for its `$CPD` and measures to there.
    func testAnUnchartedPartitionPastTheLastEntryIsFound() {
        var region = Data(repeating: 0xFF, count: 0x8000)
        region.replaceSubrange(0x3800..<0x3804, with: Data("$CPD".utf8))
        XCTAssertEqual(size([part("FTPR", 0x1000, 0x2000)], fptStart: 0x1000,
                            in: region, hasFlashDescriptor: false),
                       0x3000,
                       "measured to the uncharted 0x3800 — 0x2800 from the "
                       + "$FPT — and padded to the next 4 KiB")

        // With a descriptor or a Layout Table there is nothing uncharted to
        // look for, and the same bytes change nothing.
        XCTAssertEqual(size([part("FTPR", 0x1000, 0x2000)], fptStart: 0x1000,
                            in: region, hasFlashDescriptor: true),
                       0x2000)
    }

    // MARK: - The IFWI leg

    /// The CSME-12 oracle (`DATMAAMBAC0.BIN`): a 16 MiB dump whose firmware
    /// ends at 0x27C000 — the number upstream prints, reproduced from the
    /// Layout Table's own partitions.
    func testTheCSME12OracleReproducesItsPrintedSize() {
        let wholeFile = size([
            part("PSVN", 0x002F00, 0x000100), part("UEP", 0x06E000, 0x002000),
            part("IVBP", 0x003000, 0x004000), part("MFS", 0x007000, 0x064000),
            part("UTOK", 0x06B000, 0x002000), part("HVMP", 0x002EC0, 0x00000C),
            part("FLOG", 0x06D000, 0x001000),
        ], fptStart: 0x2000, layout: layout(base: 0x1000, [
            slot("Data", 0x002000, 0x06E000), slot("Boot 1", 0x070000, 0x103000),
            slot("Boot 2", 0x173000, 0x10A000),
            slot("Boot 3", 0x001000, 0, empty: true),
            slot("Boot 4", 0x001000, 0, empty: true),
            slot("Boot 5", 0x001000, 0, empty: true),
        ]))
        XCTAssertEqual(wholeFile, 0x27C000)

        // The same firmware handed over as the ME region alone — every offset
        // 0x1000 lower, since the region starts where the Layout Table does.
        // The firmware is the same size, and the panel reads the same row.
        let region = size([
            part("PSVN", 0x001F00, 0x000100), part("UEP", 0x06D000, 0x002000),
            part("IVBP", 0x002000, 0x004000), part("MFS", 0x006000, 0x064000),
            part("UTOK", 0x06A000, 0x002000), part("HVMP", 0x001EC0, 0x00000C),
            part("FLOG", 0x06C000, 0x001000),
        ], fptStart: 0x1000, layout: layout(base: 0, [
            slot("Data", 0x001000, 0x06E000), slot("Boot 1", 0x06F000, 0x103000),
            slot("Boot 2", 0x172000, 0x10A000),
            slot("Boot 3", 0, 0, empty: true),
            slot("Boot 4", 0, 0, empty: true),
            slot("Boot 5", 0, 0, empty: true),
        ]))
        XCTAssertEqual(region, 0x27C000, "the frame the region is measured in does not change its size")
    }

    /// A Data partition larger than the `$FPT` reaches is what the total
    /// takes: the table plus the *larger* of the two, plus the boot
    /// partitions.
    func testTheLargerOfTheFPTEndAndTheDataPartitionCounts() {
        let measured = size([part("FTPR", 0x1000, 0x1000)], fptStart: 0x1000,
                            layout: layout(base: 0, [
                                slot("Data", 0x1000, 0x8000),
                                slot("Boot 1", 0x9000, 0x1000),
                            ]))
        XCTAssertEqual(measured, 0x1000 + 0x8000 + 0x1000 - 0x1000)
    }

    /// A partition nested inside another is the same flash space twice — a
    /// redundancy layout — and is counted once.
    func testANestedPartitionIsNotCountedTwice() {
        let nested = size([part("FTPR", 0x1000, 0x1000)], fptStart: 0x1000,
                          layout: layout(base: 0, [
                            slot("Data", 0x1000, 0x2000),
                            slot("Boot 1", 0x3000, 0x4000),
                            // Inside Boot 1: its backup copy.
                            slot("Boot 2", 0x3000, 0x2000),
                          ]))
        // Table 0x1000 + max(0x2000, 0x2000) + (0x4000 + 0x2000) − 0x2000 nested
        // − fptStart 0x1000.
        XCTAssertEqual(nested, 0x6000)
    }
}
