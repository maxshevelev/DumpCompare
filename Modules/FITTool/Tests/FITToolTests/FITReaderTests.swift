import XCTest
@testable import FITTool
import UEFIFormat

/// Finding the table and reading it (§2, §3, §4).
final class FITReaderTests: XCTestCase {
    private let microcodeOffset: UInt64 = 0x2000

    private func read(_ image: [UInt8], image parsed: UEFIImage? = nil) -> FITReport {
        FITReader.read(ImageReader(image), image: parsed)
    }

    private var ordinaryImage: [UInt8] {
        TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: microcodeOffset)],
            contents: [microcodeOffset: TestFIT.microcode()]
        )
    }

    func testTheTableIsFoundThroughThePointer() {
        let report = read(ordinaryImage)

        XCTAssertEqual(report.table?.range, 0x1000..<0x1020)
        XCTAssertEqual(report.table?.pointerOffset, 0xFFC0)
        XCTAssertEqual(report.table?.pointerAddress, 0xFFFF_1000)
        XCTAssertEqual(report.table?.rows.count, 2)
        XCTAssertEqual(report.table?.entries.count, 1)
        XCTAssertTrue(report.problems.isEmpty)
    }

    /// The header's `Size` counts entries, not bytes — the field everyone reads
    /// wrong (§4).
    func testTheHeaderCountsEntriesRatherThanBytes() {
        let report = read(TestFIT.image(rows: [
            TestFIT.Row(FIT.microcodeType, target: microcodeOffset),
            TestFIT.Row(FIT.startupACMType, target: 0x3000)
        ], contents: [microcodeOffset: TestFIT.microcode()]))

        XCTAssertEqual(report.table?.header?.size, 3)
        XCTAssertEqual(report.table?.range.count, 3 * 16)
    }

    /// Without a volume top file the image is taken to be mapped against the
    /// top of the address space. That is true of a full flash dump and false of
    /// a region cut out of one, so the reading says which it did — but as a
    /// caveat about itself, not as a problem with the table.
    func testAnAssumedAddressMappingIsSaidOutLoud() {
        let report = read(ordinaryImage)

        XCTAssertTrue(report.addressDiffIsAssumed)
        XCTAssertEqual(report.addressDiff, 0xFFFF_0000)
        XCTAssertTrue(report.problems.isEmpty)
    }

    /// With a parse that found a volume top file, the mapping is the image's
    /// own and nothing is assumed.
    func testAKnownAddressMappingIsUsedAsItIs() {
        let parsed = UEFIImage(size: 0x1_0000, roots: [], addressDiff: 0xFFFF_0000)

        let report = read(ordinaryImage, image: parsed)

        XCTAssertFalse(report.addressDiffIsAssumed)
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertEqual(report.table?.range, 0x1000..<0x1020)
    }

    /// The pointer lives at a physical address, `0xFFFFFFC0`, and only in a
    /// full flash dump is that the same as forty bytes before the end of the
    /// file. An image with anything after its volume top file puts it
    /// somewhere else entirely.
    func testThePointerIsFoundByAddressAndNotFromTheEndOfTheFile() {
        let diff: UInt64 = 0xFFFF_1000               // a volume top file ending at 0xF000
        let image = TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: microcodeOffset)],
            addressDiff: diff,
            contents: [microcodeOffset: TestFIT.microcode()]
        )
        let parsed = UEFIImage(size: 0x1_0000, roots: [], addressDiff: diff)

        let report = read(image, image: parsed)

        XCTAssertEqual(report.table?.pointerOffset, 0xEFC0)
        XCTAssertEqual(report.table?.range, 0x1000..<0x1020)
        XCTAssertTrue(report.problems.isEmpty)
    }

    /// Both sides of the link are worth checking (§2.1): a pointer that leads
    /// nowhere does not mean there is no table, and the one the scan finds is
    /// still worth showing the user.
    func testAPointerLeadingNowhereStillFindsTheTableByScanning() {
        let image = TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: microcodeOffset)],
            pointerAddress: 0xFFFF_5000,
            contents: [microcodeOffset: TestFIT.microcode()]
        )

        let report = read(image)

        XCTAssertNil(report.table)
        XCTAssertEqual(report.candidates, [0x1000])
        XCTAssertTrue(report.problems.contains {
            $0.kind == .noTableAtThePointer(address: 0xFFFF_5000)
        })
    }

    func testAPointerOutsideTheImageIsReported() {
        let image = TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: microcodeOffset)],
            pointerAddress: 0x1000
        )

        let report = read(image)

        XCTAssertNil(report.table)
        XCTAssertTrue(report.problems.contains {
            $0.kind == .pointerLeadsOutsideTheImage(address: 0x1000)
        })
    }

    func testAnImageWithNoRoomForAPointerIsReported() {
        let report = read([UInt8](repeating: 0xFF, count: 0x20))

        XCTAssertNil(report.table)
        XCTAssertTrue(report.problems.contains { $0.kind == .imageHasNoPointer })
    }

    /// A count of zero, believed, is a table of nothing.
    func testAHeaderWithNoEntriesIsReported() {
        let image = TestFIT.image(rows: [], entryCount: 0)

        let report = read(image)

        XCTAssertNil(report.table)
        XCTAssertTrue(report.problems.contains { $0.kind == .tableHasNoEntries })
    }

    /// A count that runs past the end: read what is there, and say the rest is
    /// not (§8.3).
    func testATableRunningPastTheEndIsCutAndReported() {
        let image = TestFIT.image(
            size: 0x1_0000,
            tableOffset: 0xFFE0,
            rows: [TestFIT.Row(FIT.microcodeType, target: microcodeOffset)],
            entryCount: 0x100,
            contents: [microcodeOffset: TestFIT.microcode()]
        )

        let report = read(image)

        XCTAssertEqual(report.table?.rows.count, 2)
        XCTAssertTrue(report.problems.contains { $0.kind == .tableRunsPastTheEnd(entries: 0x100) })
    }

    // MARK: - Rows

    func testARowIsReadFieldByField() {
        let image = TestFIT.image(rows: [
            TestFIT.Row(FIT.cseSecureBootType, target: 0x3000, size: 2, reserved: 8, version: 0x0100)
        ], contents: [microcodeOffset: TestFIT.microcode()])

        let entry = read(image).table?.entries.first?.entry

        XCTAssertEqual(entry?.index, 1)
        XCTAssertEqual(entry?.offset, 0x1010)
        XCTAssertEqual(entry?.address, 0xFFFF_3000)
        XCTAssertEqual(entry?.size, 2)
        XCTAssertEqual(entry?.sizeInBytes, 0x20)
        XCTAssertEqual(entry?.reserved, 8)
        XCTAssertEqual(entry?.versionText, "1.00")
        XCTAssertEqual(entry?.type, FIT.cseSecureBootType)
        XCTAssertFalse(entry?.checksumValid ?? true)
    }

    /// The seven-bit type and the eighth bit that is not part of it.
    func testTheChecksumValidBitIsNotPartOfTheType() {
        let image = TestFIT.image(rows: [], entryCount: 1, checksumValid: true)

        XCTAssertEqual(read(image).table?.header?.type, FIT.headerType)
        XCTAssertEqual(read(image).table?.checksumIsChecked, true)
    }
}
