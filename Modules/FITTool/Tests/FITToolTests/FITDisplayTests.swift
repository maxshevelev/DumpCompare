import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIFormat

/// What the panel draws, decided here so the view controller has no decisions
/// left in it.
final class FITDisplayTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    private func display(
        _ rows: [TestFIT.Row],
        checksum: UInt8? = nil,
        checksumValid: Bool = true,
        focus: Int? = nil,
        pointerAddress: UInt64? = nil
    ) -> FITDisplay {
        let bytes = TestFIT.image(
            rows: rows,
            pointerAddress: pointerAddress,
            checksum: checksum,
            checksumValid: checksumValid,
            contents: [microcode: TestFIT.microcode(totalSize: 0x180)]
        )
        let parsed = UEFIImage(size: 0x1_0000, roots: [], addressDiff: 0xFFFF_0000)
        return FITPresenter.display(
            FITReader.read(ImageReader(bytes), image: parsed), focus: focus
        )
    }

    private var microcodeRow: TestFIT.Row { TestFIT.Row(FIT.microcodeType, target: microcode) }

    func testTheSummarySaysWhereTheTableIsAndWhetherItAddsUp() {
        XCTAssertEqual(
            display([microcodeRow]).summary,
            "FIT at 0x1000 · 1 entry · checksum 0x5C"
        )
    }

    func testTheSummarySaysWhatTheChecksumShouldHaveBeen() {
        XCTAssertEqual(
            display([microcodeRow], checksum: 0xCC).summary,
            "FIT at 0x1000 · 1 entry · checksum 0xCC, should be 0x5C"
        )
    }

    /// A region cut out of a dump has no volume top file, and then every
    /// address in the table is wrong by whatever was cut off in front of it.
    /// The summary says which reading it did, every time.
    func testTheSummarySaysWhenTheMappingWasAssumed() {
        let bytes = TestFIT.image(
            rows: [microcodeRow],
            contents: [microcode: TestFIT.microcode(totalSize: 0x180)]
        )
        let shown = FITPresenter.display(FITReader.read(ImageReader(bytes), image: nil))

        XCTAssertEqual(
            shown.summary,
            "FIT at 0x1000 · 1 entry · addresses assumed · checksum 0x5C"
        )
        XCTAssertTrue(shown.problems.isEmpty)
    }

    /// A table whose header says the checksum does not count is not wrong for
    /// having a stale one, and the summary should not imply that it is (§5).
    func testTheSummarySaysWhenTheChecksumIsNotUsed() {
        XCTAssertEqual(
            display([microcodeRow], checksum: 0xCC, checksumValid: false).summary,
            "FIT at 0x1000 · 1 entry · checksum unused"
        )
    }

    func testTheSummaryOffersTheCandidatesWhenThePointerHasLostTheTable() {
        let shown = display([microcodeRow], pointerAddress: 0xFFFF_5000)

        XCTAssertEqual(
            shown.summary,
            "No FIT table where the pointer leads. A signature sits at 0x1000."
        )
        XCTAssertTrue(shown.rows.isEmpty)
    }

    /// A microcode row leads with its CPUID rather than with the word
    /// "microcode" — the type column has said that already, and the CPUID is
    /// the thing being looked for. Five hex digits, no leading zero, the way a
    /// bench writes it.
    func testAMicrocodeRowLeadsWithItsCpuid() {
        let row = display([microcodeRow]).rows[1]

        XCTAssertEqual(row.typeText, "Microcode")
        XCTAssertEqual(row.addressText, "0xFFFF2000")
        XCTAssertEqual(row.cpuidText, "806EA")
        XCTAssertEqual(row.targetText, "806EA · rev F0 · 2019-07-15 · 0x2000 · 0x180")
        XCTAssertEqual(row.targetRange, microcode..<(microcode + 0x180))
        XCTAssertFalse(row.hasProblem)
    }

    /// A row's own size field is required to be zero for most types, so where
    /// there is nothing to say the line does not end with a `0x0` that looks
    /// like a size (§11).
    func testARowThatLeadsSomewhereElseStillSaysWhereAndHowLong() {
        let node = UEFINode(kind: .volume, name: "FFSv2", range: 0x2800..<0x4000)
        let image = UEFIImage(size: 0x1_0000, roots: [node], addressDiff: 0xFFFF_0000)
        let bytes = TestFIT.image(rows: [TestFIT.Row(FIT.startupACMType, target: 0x3000)])
        let row = FITPresenter.display(
            FITReader.read(ImageReader(bytes), image: image)
        ).rows[1]

        XCTAssertNil(row.cpuidText)
        XCTAssertEqual(row.targetText, "FFSv2 · 0x3000")
    }

    /// The header's `Size` counts entries, not bytes — the field everyone reads
    /// wrong (§4) — so the row says it both ways rather than showing `0x50` and
    /// leaving the reader to guess which it meant.
    func testTheHeaderRowSaysItsCountBothWays() {
        let row = display([microcodeRow]).rows[0]

        XCTAssertEqual(row.addressText, "_FIT_")
        XCTAssertEqual(row.typeText, "FIT Header")
        XCTAssertEqual(row.targetText, "2 rows · 0x20")
    }

    /// The reserved byte is a subtype here, and saying so is the difference
    /// between a row that means something and a row that does not (§7.5).
    func testACseSecureBootRowNamesItsSubtype() {
        let row = display([
            microcodeRow,
            TestFIT.Row(FIT.cseSecureBootType, target: 0x3000, reserved: 8)
        ]).rows[2]

        XCTAssertEqual(row.typeText, "CSE SecureBoot Settings: IBB Hash")
    }

    /// A row the validator complained about is marked where the eye lands on
    /// it, not only in the list underneath.
    func testARowWithAProblemIsMarked() {
        let shown = display([TestFIT.Row(FIT.microcodeType, target: microcode + 4)])

        XCTAssertTrue(shown.rows[1].hasProblem)
        XCTAssertFalse(shown.rows[0].hasProblem)
    }

    // MARK: - Zones

    /// The table, the pointer that leads to it, every row, and what every row
    /// points at — the last being the useful one, since the components are
    /// scattered across the image and the table is not.
    func testTheZonesCoverTheTableThePointerAndWhatTheRowsPointAt() {
        let zones = display([microcodeRow]).zones

        XCTAssertEqual(zones.zones.map(\.id).sorted(), [
            "fit.pointer", "fit.row.0", "fit.row.1", "fit.table", "fit.target.1"
        ])
        XCTAssertEqual(zones.zones.first { $0.id == "fit.table" }?.range, 0x1000..<0x1020)
        XCTAssertEqual(zones.zones.first { $0.id == "fit.pointer" }?.range, 0xFFC0..<0xFFC4)
        XCTAssertEqual(zones.zones.first { $0.id == "fit.row.1" }?.range, 0x1010..<0x1020)
        XCTAssertEqual(
            zones.zones.first { $0.id == "fit.target.1" }?.range,
            microcode..<(microcode + 0x180)
        )
    }

    /// Every microcode in the table is a zone from the moment it is read, named
    /// by the CPUID — which is what a bench is hunting for in a dump.
    func testEveryMicrocodeIsAZoneNamedByItsCpuid() {
        let zones = display([
            microcodeRow,
            TestFIT.Row(FIT.microcodeType, target: 0x3000)
        ]).zones

        XCTAssertEqual(zones.zones.first { $0.id == "fit.row.1" }?.name, "#1 Microcode")
        XCTAssertEqual(zones.zones.first { $0.id == "fit.target.1" }?.name, "CPUID 806EA")
        XCTAssertEqual(zones.zones.first { $0.id == "fit.target.2" }?.range, 0x3000..<0x3010)
    }

    /// Going to an offset puts the component in focus, not the row that names
    /// it.
    func testGoingToATargetFocusesTheComponent() {
        XCTAssertEqual(
            display([microcodeRow]).focusingTarget(of: 1).zones.focus,
            "fit.target.1"
        )
    }

    /// Selecting a row moves the outline drawn strongly in the dump. It is a
    /// change to the focus and not a reason to read the file again.
    func testSelectingARowFocusesItsZone() {
        XCTAssertNil(display([microcodeRow]).zones.focus)
        XCTAssertEqual(display([microcodeRow], focus: 1).zones.focus, "fit.row.1")

        let refocused = display([microcodeRow], focus: 1).focusing(0)
        XCTAssertEqual(refocused.zones.focus, "fit.row.0")
        XCTAssertEqual(refocused.rows, display([microcodeRow], focus: 1).rows)
    }

    // MARK: - The right-button menu

    /// What is on offer is decided here and not in the view, and an item that
    /// does not apply to the row is absent rather than greyed.
    func testAMicrocodeRowOffersItsCpuidAndItsOffset() {
        let rows = display([microcodeRow, TestFIT.Row(FIT.emptyType, address: 0)]).rows

        XCTAssertEqual(rows[1].commands, [.copyCPUID("806EA"), .goToOffset(microcode)])
        XCTAssertEqual(rows[1].commands.map(\.title), ["Copy CPUID", "Go to Offset"])
        XCTAssertTrue(rows[0].commands.isEmpty)       // the header points nowhere
        XCTAssertTrue(rows[2].commands.isEmpty)       // and neither does an empty slot
    }

    /// A row that leads somewhere without leading to microcode can still be
    /// gone to.
    func testARowWithNoCpuidStillOffersItsOffset() {
        let rows = display([TestFIT.Row(FIT.startupACMType, target: 0x3000)]).rows

        XCTAssertEqual(rows[1].commands, [.goToOffset(0x3000)])
    }

    // MARK: - The one repair

    /// The second defect of §11, and the one a tool can put right on its own.
    func testAStaleChecksumIsOfferedAsAOneByteRepair() {
        let fix = display([microcodeRow], checksum: 0xCC).checksumFix

        XCTAssertEqual(fix?.name, "Fix FIT Checksum")
        XCTAssertEqual(fix?.writes.map(\.offset), [0x100F])
        XCTAssertEqual(fix?.writes.map(\.bytes), [[0x5C]])
        XCTAssertNoThrow(try fix?.validated())
    }

    func testNothingIsOfferedWhenTheChecksumIsRightOrUnused() {
        XCTAssertNil(display([microcodeRow]).checksumFix)
        XCTAssertNil(display([microcodeRow], checksum: 0xCC, checksumValid: false).checksumFix)
    }
}
