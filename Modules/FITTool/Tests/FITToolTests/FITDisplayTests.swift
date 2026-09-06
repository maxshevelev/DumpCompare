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

    /// A microcode row's own size field is required to be zero; the size shown
    /// is the component's (§7.1, §11).
    func testAMicrocodeRowShowsTheSizeOfTheComponent() {
        let row = display([microcodeRow]).rows[1]

        XCTAssertEqual(row.typeText, "Microcode")
        XCTAssertEqual(row.addressText, "0xFFFF2000")
        XCTAssertEqual(row.sizeText, "0x180")
        XCTAssertEqual(row.targetText, "Microcode 0x000806EA, revision 0xF0, 2019-07-15")
        XCTAssertEqual(row.targetRange, microcode..<(microcode + 0x180))
        XCTAssertFalse(row.hasProblem)
    }

    /// Not `0x0`, which is indistinguishable from a size that was never
    /// written — the confusion §11 is about.
    func testARowWithNoSizeShowsNothingRatherThanZero() {
        let row = display([TestFIT.Row(FIT.startupACMType, target: 0x3000)]).rows[1]

        XCTAssertEqual(row.sizeText, "")
    }

    func testTheHeaderRowShowsItsSignatureRatherThanAnAddress() {
        XCTAssertEqual(display([microcodeRow]).rows[0].addressText, "_FIT_")
        XCTAssertEqual(display([microcodeRow]).rows[0].typeText, "FIT Header")
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

    func testTheZonesAreNamedAsTheRowsAre() {
        let zones = display([microcodeRow]).zones

        XCTAssertEqual(zones.zones.first { $0.id == "fit.row.1" }?.name, "#1 Microcode")
        XCTAssertEqual(
            zones.zones.first { $0.id == "fit.target.1" }?.name,
            "Microcode 0x000806EA, revision 0xF0, 2019-07-15"
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
