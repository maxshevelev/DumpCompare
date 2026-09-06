import XCTest
@testable import FITTool
import UEFIFormat

/// The invariants of §8 — the list a bench opens this panel to read.
final class FITValidatorTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    private func problems(
        _ rows: [TestFIT.Row],
        checksum: UInt8? = nil,
        checksumValid: Bool = true,
        headerType: UInt8 = FIT.headerType
    ) -> [FITProblem] {
        let bytes = TestFIT.image(
            rows: rows,
            checksum: checksum,
            checksumValid: checksumValid,
            headerType: headerType,
            contents: [microcode: TestFIT.microcode()]
        )
        return FITReader.read(ImageReader(bytes), image: nil).problems
            .filter { $0.severity == .error }
    }

    private var goodRow: TestFIT.Row { TestFIT.Row(FIT.microcodeType, target: microcode) }

    func testAGoodTableHasNothingWrongWithIt() {
        XCTAssertTrue(problems([goodRow]).isEmpty)
    }

    /// A FIT handler is allowed to stop looking at the first type past the one
    /// it wants, so order is a rule and not a preference (§3, §8.5).
    func testTypesThatDecreaseAreReported() {
        let found = problems([
            TestFIT.Row(FIT.startupACMType, target: 0x3000),
            goodRow
        ])

        XCTAssertEqual(found.map(\.kind), [
            .typesOutOfOrder(previous: FIT.startupACMType, type: FIT.microcodeType)
        ])
        XCTAssertEqual(found.first?.entryIndex, 2)
    }

    func testASecondHeaderIsReported() {
        let found = problems([goodRow, TestFIT.Row(FIT.headerType, address: 0)])

        XCTAssertTrue(found.contains { $0.kind == .secondHeader && $0.entryIndex == 2 })
    }

    func testAFirstEntryThatIsNotTheHeaderIsReported() {
        let found = problems([goodRow], headerType: FIT.microcodeType)

        XCTAssertTrue(found.contains {
            $0.kind == .firstEntryIsNotTheHeader(type: FIT.microcodeType)
        })
    }

    /// There must be microcode. A table without it will not boot the machine it
    /// came out of (§8.7).
    func testATableWithNoMicrocodeIsReported() {
        let found = problems([TestFIT.Row(FIT.startupACMType, target: 0x3000)])

        XCTAssertTrue(found.contains { $0.kind == .noMicrocodeEntry })
    }

    /// The second defect of §11: the checksum left over from the edit before.
    func testAStaleChecksumIsReported() {
        let found = problems([goodRow], checksum: 0xCC)

        XCTAssertEqual(found.count, 1)
        guard case .checksumMismatch(let stored, let computed) = found[0].kind else {
            return XCTFail("expected a checksum problem")
        }
        XCTAssertEqual(stored, 0xCC)
        XCTAssertNotEqual(computed, 0xCC)
        XCTAssertEqual(found[0].offset, 0x100F)
    }

    /// The header's own bit decides whether anyone checks the sum (§5), so a
    /// table that never claimed a checksum is not wrong for having none.
    func testAChecksumIsNotCheckedWhenTheHeaderSaysItDoesNotCount() {
        XCTAssertTrue(problems([goodRow], checksum: 0xCC, checksumValid: false).isEmpty)
    }

    func testAnAddressThatIsNotAlignedIsReported() {
        let found = problems([TestFIT.Row(FIT.microcodeType, target: microcode + 4)])

        XCTAssertTrue(found.contains { $0.kind == .addressNotAligned(address: 0xFFFF_2004) })
    }

    func testAnAddressOutsideTheImageIsReported() {
        let found = problems([goodRow, TestFIT.Row(FIT.startupACMType, address: 0x40)])

        XCTAssertTrue(found.contains { $0.kind == .addressOutsideTheImage(address: 0x40) })
    }

    /// The reserved byte is a subtype on a CSE SecureBoot entry and reserved
    /// everywhere else (§3, §7.5) — a rule that reads as noise if it is applied
    /// to the one type that breaks it.
    func testAReservedByteInUseIsAWarningExceptWhereItIsASubtype() {
        let bytes = TestFIT.image(
            rows: [goodRow, TestFIT.Row(FIT.startupACMType, target: 0x3000, reserved: 3)],
            contents: [microcode: TestFIT.microcode()]
        )
        let found = FITReader.read(ImageReader(bytes), image: nil).problems

        XCTAssertTrue(found.contains {
            $0.kind == .reservedIsNotZero(value: 3) && $0.severity == .warning
        })

        let cse = TestFIT.image(
            rows: [goodRow, TestFIT.Row(FIT.cseSecureBootType, target: 0x3000, reserved: 8)],
            contents: [microcode: TestFIT.microcode()]
        )
        XCTAssertFalse(FITReader.read(ImageReader(cse), image: nil).problems.contains {
            if case .reservedIsNotZero = $0.kind { return true }
            return false
        })
    }

    /// Every problem knows where to send the dump.
    func testEveryProblemPointsSomewhere() {
        let found = problems([
            TestFIT.Row(FIT.startupACMType, address: 0x40),
            goodRow
        ], checksum: 0xCC)

        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.offset != nil })
        XCTAssertFalse(found.contains { $0.message.isEmpty })
    }
}
