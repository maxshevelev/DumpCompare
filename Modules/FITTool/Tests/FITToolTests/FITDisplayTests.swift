import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIImage

/// What the panel draws, decided here so the view controller has no decisions
/// left in it.
final class FITDisplayTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    private func display(
        _ rows: [TestFIT.Row],
        checksum: UInt8? = nil,
        checksumValid: Bool = true,
        focus: Int? = nil,
        pointerAddress: UInt64? = nil,
        microcodeSignature: UInt32 = 0x0008_06EA,
        microcodeRevision: UInt32 = 0xF0,
        microcodePlatform: UInt32 = 1
    ) -> FITDisplay {
        let bytes = TestFIT.image(
            rows: rows,
            pointerAddress: pointerAddress,
            checksum: checksum,
            checksumValid: checksumValid,
            contents: [microcode: TestFIT.microcode(
                signature: microcodeSignature,
                revision: microcodeRevision,
                totalSize: 0x180,
                platformIDs: microcodePlatform
            )]
        )
        let parsed = UEFIImage(size: 0x1_0000, roots: [], addressDiff: 0xFFFF_0000)
        return FITPresenter.display(
            FITReader.read(ImageReader(bytes), image: parsed), focus: focus
        )
    }

    /// One Intel catalogue entry, as the file name would write it — the reading
    /// of the name is the thing under test, so the name is written plainly.
    private func catalogueEntry(
        cpuid: UInt32, platform: UInt32, revision: UInt32
    ) throws -> MicrocodeCatalogueEntry {
        let platformText = String(platform, radix: 16, uppercase: true)
        let padded = platformText.count < 2 ? "0" + platformText : platformText
        let name = "Intel/cpu\(String(cpuid, radix: 16, uppercase: true))"
            + "_plat\(padded)_ver\(String(revision, radix: 16, uppercase: true))"
            + "_2019-01-01_PRD_5046D998.bin"
        return try XCTUnwrap(MicrocodeCatalogue.entry(at: name, size: 0x100))
    }

    private var microcodeRow: TestFIT.Row { TestFIT.Row(FIT.microcodeType, target: microcode) }

    func testTheSummarySaysWhereTheTableIsAndWhetherItAddsUp() {
        // The count includes the header row, so one microcode reads as two.
        XCTAssertEqual(
            display([microcodeRow]).summary,
            "FIT at 0x1000 · 2 entries · checksum 0x5C"
        )
    }

    /// A wrong checksum is a problem, and the list below says so in red — so
    /// the summary keeps only what is not an error and does not restate it.
    func testTheSummaryDoesNotRestateAWrongChecksum() {
        XCTAssertEqual(
            display([microcodeRow], checksum: 0xCC).summary,
            "FIT at 0x1000 · 2 entries"
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
            "FIT at 0x1000 · 2 entries · addresses assumed · checksum 0x5C"
        )
        XCTAssertTrue(shown.problems.isEmpty)
    }

    /// A table whose header says the checksum does not count is not wrong for
    /// having a stale one, and the summary should not imply that it is (§5).
    func testTheSummarySaysWhenTheChecksumIsNotUsed() {
        XCTAssertEqual(
            display([microcodeRow], checksum: 0xCC, checksumValid: false).summary,
            "FIT at 0x1000 · 2 entries · checksum unused"
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
        // The size has its own column now; for a microcode it is the
        // component's, not the row's zero field (§7.1) — hex, the way the
        // column shows every size.
        XCTAssertEqual(row.targetText, "CPUID 806EA · r.F0 · 2019-07-15")
        XCTAssertEqual(row.sizeText, "0x180")
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
        // The header's size field counts entries, so its column says so.
        XCTAssertEqual(row.sizeText, "2 rows")
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

        // The row's number counts from one, so the first microcode — the row
        // after the header — is the second row, not the first.
        XCTAssertEqual(zones.zones.first { $0.id == "fit.row.1" }?.name, "#2 Microcode")
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
    /// does not apply to the row is absent rather than greyed. The one
    /// microcode may be replaced but not removed: the slot stays, so the
    /// one-microcode rule is not touched by a swap.
    func testAMicrocodeRowOffersItsCpuidAndItsOffset() {
        let rows = display([microcodeRow]).rows

        XCTAssertEqual(rows[1].commands,
                       [.goToOffset(microcode), .copyCPUID("806EA"), .replaceMicrocode(1)])
        XCTAssertEqual(rows[1].commands.map(\.title),
                       ["Go to Offset", "Copy CPUID", "Replace Microcode"])
    }

    /// Every microcode row may be replaced — the slot stays, so even the last
    /// and only one is offered it, where it is not offered removal. A row that
    /// is not a microcode is offered neither.
    func testEveryMicrocodeRowOffersItsReplacement() {
        let one = display([microcodeRow]).rows
        XCTAssertTrue(one[1].canReplace)
        XCTAssertTrue(one[1].commands.contains(.replaceMicrocode(1)))

        let two = display([microcodeRow, TestFIT.Row(FIT.microcodeType, target: 0x3000)]).rows
        XCTAssertTrue(two[1].canReplace)
        XCTAssertTrue(two[2].canReplace)

        let acm = display([TestFIT.Row(FIT.startupACMType, target: 0x3000)]).rows
        XCTAssertFalse(acm[1].canReplace)
        XCTAssertFalse(acm[1].commands.contains { $0.title == "Replace Microcode" })
    }

    /// A row that points nowhere — the header, an empty slot — still has an
    /// offset of its own, so it still goes somewhere: to its own sixteen bytes
    /// in the table.
    func testARowThatPointsNowhereGoesToItself() {
        let rows = display([microcodeRow, TestFIT.Row(FIT.emptyType, address: 0)]).rows

        // Only a microcode is offered for removal, so neither the header nor
        // the empty slot has it.
        XCTAssertEqual(rows[0].commands, [.goToOffset(0x1000)])
        XCTAssertEqual(rows[2].commands, [.goToOffset(0x1020)])
        XCTAssertEqual(rows[0].zoneToFocus, "fit.row.0")
        XCTAssertEqual(rows[2].zoneToFocus, "fit.row.2")
    }

    /// A row that leads somewhere without leading to microcode can still be
    /// gone to, and it is the component that comes into focus. It is not a
    /// microcode, so it is not offered for removal either.
    func testARowWithNoCpuidStillOffersItsOffset() {
        let rows = display([TestFIT.Row(FIT.startupACMType, target: 0x3000)]).rows

        XCTAssertEqual(rows[1].commands, [.goToOffset(0x3000)])
        XCTAssertEqual(rows[1].zoneToFocus, "fit.target.1")
    }

    /// A table needs one microcode entry (§8.7), so the only one is not offered
    /// for removal at all — rather than offered and then refused.
    func testTheLastMicrocodeIsNotOfferedForRemoval() {
        let one = display([microcodeRow]).rows
        XCTAssertFalse(one[1].canRemove)
        XCTAssertFalse(one[1].commands.contains { $0.title == "Remove Microcode" })

        let two = display([microcodeRow, TestFIT.Row(FIT.microcodeType, target: 0x3000)]).rows
        XCTAssertTrue(two[1].canRemove)
        XCTAssertTrue(two[2].canRemove)
    }

    /// The checksum byte is the header's (§5), so the fix is offered on the
    /// header row — the one the mismatch turns red — and on no other: a row
    /// that is not the header is not where the byte lives, and a table whose
    /// checksum is right offers nothing at all.
    func testTheChecksumFixIsOfferedOnlyOnTheHeaderRow() {
        let broken = display([microcodeRow], checksum: 0xCC).rows
        XCTAssertTrue(broken[0].checksumFixAvailable)
        XCTAssertTrue(broken[0].commands.contains(.fixChecksum))
        // The microcode row is not where the byte lives, so it does not offer
        // the fix even though the table needs it.
        XCTAssertFalse(broken[1].checksumFixAvailable)
        XCTAssertFalse(broken[1].commands.contains(.fixChecksum))

        let good = display([microcodeRow]).rows
        XCTAssertFalse(good[0].checksumFixAvailable)
        XCTAssertFalse(good[0].commands.contains(.fixChecksum))
        XCTAssertFalse(good[1].checksumFixAvailable)
        XCTAssertFalse(good[1].commands.contains(.fixChecksum))
    }

    /// The trip back: the user picks a zone in the dump, and the panel has to
    /// know which row it came from.
    func testAZoneIdSaysWhichRowItCameFrom() {
        XCTAssertEqual(FITPresenter.rowIndex(ofZone: "fit.row.3"), 3)
        XCTAssertEqual(FITPresenter.rowIndex(ofZone: "fit.target.12"), 12)
        XCTAssertNil(FITPresenter.rowIndex(ofZone: FITPresenter.tableZoneID))
        XCTAssertNil(FITPresenter.rowIndex(ofZone: FITPresenter.pointerZoneID))
        XCTAssertNil(FITPresenter.rowIndex(ofZone: "fit.row.x"))
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

    // MARK: - "Latest" against the catalogue

    /// Before the catalogue is applied no row has a verdict: a display built
    /// fresh from a parse does not know what is out there.
    func testEveryRowStartsWithoutALatestVerdict() {
        XCTAssertEqual(display([microcodeRow]).rows.map(\.latestState),
                       [.notRated, .notRated])
    }

    /// Applying an empty catalogue — nothing fetched, or the fetch failed — is
    /// a no-op: it must not flip a display into pretending a verdict exists.
    func testAnEmptyCatalogueLeavesTheVerdictsUnrated() {
        let shown = display([microcodeRow]).ratingLatest(against: [])
        XCTAssertEqual(shown.rows.map(\.latestState), [.notRated, .notRated])
    }

    /// The row whose revision is the newest the catalogue lists for its CPUID
    /// and platform is the latest one, and only the microcode rows are judged —
    /// the header is not a microcode, whatever the catalogue holds.
    func testTheRowMatchingTheCataloguesNewestIsLatest() throws {
        var shown = display([microcodeRow], microcodePlatform: 0x02)
        shown = shown.ratingLatest(against: [
            try catalogueEntry(cpuid: 0x0008_06EA, platform: 0x02, revision: 0x7C),
            try catalogueEntry(cpuid: 0x0008_06EA, platform: 0x02, revision: 0xF0)
        ])

        XCTAssertEqual(shown.rows[1].latestState, .latest)
        XCTAssertEqual(shown.rows[0].latestState, .notRated,
                       "the header row is not a microcode and has no verdict")
    }

    /// An installed revision behind the catalogue's newest for the same CPUID
    /// and platform is outdated, and the verdict names the newer revision.
    func testARowBehindTheCatalogueIsOutdatedAndNamesTheNewerRevision() throws {
        var shown = display([microcodeRow], microcodeRevision: 0x7C,
                            microcodePlatform: 0x02)
        shown = shown.ratingLatest(against: [
            try catalogueEntry(cpuid: 0x0008_06EA, platform: 0x02, revision: 0xF0)
        ])

        XCTAssertEqual(shown.rows[1].latestState, .outdated(newestRevision: 0xF0))
    }

    /// The platform is part of the match, not a refinement: an update for one
    /// platform does not outdate an update for another, no matter how its
    /// revision compares.
    func testThePlatformIsPartOfTheMatch() throws {
        // The catalogue's newest 806EA is for plat02; this row is for plat22.
        var shown = display([microcodeRow], microcodePlatform: 0x22)
        shown = shown.ratingLatest(against: [
            try catalogueEntry(cpuid: 0x0008_06EA, platform: 0x02, revision: 0xF0)
        ])

        XCTAssertEqual(shown.rows[1].latestState, .notRated)
    }

    /// A CPUID the catalogue holds nothing for has no verdict: the collection
    /// cannot say anything about a processor it does not list.
    func testACpuidTheCatalogueDoesNotListIsNotRated() throws {
        var shown = display([microcodeRow], microcodePlatform: 0x02)
        shown = shown.ratingLatest(against: [
            try catalogueEntry(cpuid: 0x0009_06EB, platform: 0x02, revision: 0xF0)
        ])

        XCTAssertEqual(shown.rows[1].latestState, .notRated)
    }

    /// A revision newer than anything the catalogue lists is not "latest": the
    /// collection is behind the board, and a behind catalogue cannot confirm
    /// what it does not know.
    func testARowNewerThanTheCatalogueIsNotRatedNotLatest() throws {
        var shown = display([microcodeRow], microcodeRevision: 0x100)
        shown = shown.ratingLatest(against: [
            try catalogueEntry(cpuid: 0x0008_06EA, platform: 0x01, revision: 0xF0)
        ])

        XCTAssertEqual(shown.rows[1].latestState, .notRated)
    }
}
