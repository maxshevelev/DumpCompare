import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIFormat

/// Adding a microcode entry (§9.2) and taking one out (§10).
final class FITEditorTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    /// An image with one microcode in it and erased space after it.
    private func image(
        rows: [TestFIT.Row]? = nil,
        tableOffset: UInt64 = 0x1000,
        contents extra: [UInt64: [UInt8]] = [:]
    ) -> [UInt8] {
        var contents = [microcode: TestFIT.microcode(totalSize: 0x100)]
        contents.merge(extra) { _, new in new }
        return TestFIT.image(
            tableOffset: tableOffset,
            rows: rows ?? [TestFIT.Row(FIT.microcodeType, target: microcode)],
            contents: contents
        )
    }

    private func table(_ bytes: [UInt8]) throws -> FITTable {
        try XCTUnwrap(FITReader.read(ImageReader(bytes), image: nil).table)
    }

    private func applying(_ transaction: ToolTransaction, to bytes: [UInt8]) throws -> [UInt8] {
        var edited = bytes
        for write in try transaction.validated().writes {
            edited.replaceSubrange(
                Int(write.offset)..<(Int(write.offset) + write.bytes.count), with: write.bytes
            )
        }
        return edited
    }

    private func placement(
        _ bytes: [UInt8], size: UInt64 = 0x100, image: UEFIImage? = nil
    ) throws -> Result<FITPlacement, FITEditProblem> {
        FITEditor.placement(
            forSize: size,
            table: try table(bytes),
            image: image,
            reader: ImageReader(bytes),
            addressDiff: TestFIT.addressDiff(of: UInt64(bytes.count))
        )
    }

    // MARK: - The file the user picked

    func testAFileThatIsNotMicrocodeIsRefused() {
        XCTAssertEqual(
            FITEditor.microcode(in: [UInt8](repeating: 0x5A, count: 0x100)),
            .failure(.notMicrocode)
        )
        XCTAssertEqual(FITEditor.microcode(in: []), .failure(.notMicrocode))
    }

    /// Every dword of a microcode image sums to zero (§7.1). One that does not
    /// is not going to be loaded by anything.
    func testAMicrocodeWithABrokenChecksumIsRefused() {
        var bytes = TestFIT.microcode()
        bytes[0x40] ^= 0xFF

        XCTAssertEqual(FITEditor.microcode(in: bytes), .failure(.microcodeChecksumIsWrong))
    }

    func testAGoodMicrocodeComesBackWithItsHeader() throws {
        let header = try FITEditor.microcode(in: TestFIT.microcode(totalSize: 0x180)).get()

        XCTAssertEqual(header.processorSignature, 0x0008_06EA)
        XCTAssertEqual(header.totalSize, 0x180)
    }

    // MARK: - Where it goes

    /// Microcode lives in one run, so a new one goes right after the last —
    /// aligned to sixteen, which every FIT address must be (§8.9).
    func testTheComponentGoesAfterTheLastMicrocode() throws {
        let found = try placement(image()).get()

        XCTAssertEqual(found.range, 0x2100..<0x2200)
        XCTAssertEqual(found.address, 0xFFFF_2100)
    }

    /// Every FIT address is aligned to sixteen (§8.9), and a component whose
    /// size is not a multiple of sixteen leaves the next start unaligned unless
    /// it is rounded up.
    func testTheComponentStartsOnASixteenByteBoundary() throws {
        let bytes = TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: microcode)],
            contents: [microcode: TestFIT.microcode(totalSize: 0x108)]
        )

        XCTAssertEqual(try placement(bytes).get().range.lowerBound, 0x2110)
    }

    /// Bytes in the way are stepped over, and the next candidate is aligned
    /// again rather than butted up against them.
    func testBytesInTheWayArePassed() throws {
        let bytes = image(contents: [0x2180: [0x11, 0x22]])

        XCTAssertEqual(try placement(bytes).get().range, 0x2190..<0x2290)
    }

    /// After the *last* one, which is not the first one the table happens to
    /// name: rows are ordered by type, not by address.
    func testTheComponentGoesAfterTheHighestMicrocodeNotTheFirstListed() throws {
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: microcode),
                TestFIT.Row(FIT.microcodeType, target: 0x2200)
            ],
            contents: [
                microcode: TestFIT.microcode(totalSize: 0x100),
                0x2200: TestFIT.microcode(signature: 0x000906EA, totalSize: 0x100)
            ]
        )

        XCTAssertEqual(try placement(bytes).get().range, 0x2300..<0x2400)
    }

    /// With no microcode in the table there is no telling where this image
    /// keeps it, and guessing is how a component lands in the wrong region.
    func testATableWithNoMicrocodeHasNowhereToPutOne() throws {
        let bytes = image(rows: [TestFIT.Row(FIT.startupACMType, target: 0x3000)])

        XCTAssertEqual(try placement(bytes), .failure(.noMicrocodeToFollow))
    }

    /// The element the existing microcode sits in bounds the search: past its
    /// end is another structure, or another flash region.
    func testTheSearchStaysInsideWhatHoldsTheMicrocode() throws {
        let bytes = image()
        let padding = UEFINode(kind: .padding, name: "Padding", range: 0x1800..<0x2180)
        let parsed = UEFIImage(size: UInt64(bytes.count), roots: [padding], addressDiff: 0xFFFF_0000)

        XCTAssertEqual(
            try placement(bytes, image: parsed),
            .failure(.noRoomForTheComponent(needed: 0x100))
        )
    }

    /// A microcode found by the raw scan of an image with no volumes in it is a
    /// node with no parent, and then there is nothing to bound the search but
    /// the file. Reading the component's own node as the bound leaves no room
    /// at all — which is what the app's own test caught first.
    func testAMicrocodeWithNoParentIsBoundedByTheFile() throws {
        let bytes = image()
        let node = UEFINode(kind: .microcode, name: "Microcode", range: microcode..<(microcode + 0x100))
        let parsed = UEFIImage(size: UInt64(bytes.count), roots: [node], addressDiff: 0xFFFF_0000)

        XCTAssertEqual(try placement(bytes, image: parsed).get().range, 0x2100..<0x2200)
    }

    // MARK: - Adding

    /// The whole edit is one transaction: the component and the table it is
    /// named in land together or not at all.
    func testAddingWritesTheComponentAndTheTableTogether() throws {
        let bytes = image()
        let component = TestFIT.microcode(signature: 0x000906EA, totalSize: 0x100)
        let found = try placement(bytes).get()

        let transaction = try FITEditor.addMicrocode(
            component, at: found, to: try table(bytes), in: ImageReader(bytes)
        ).get()

        XCTAssertEqual(transaction.name, "Add Microcode")
        // Sorted and checked for overlap by the transaction itself, which is
        // where "the component landed on top of the table" would be caught.
        XCTAssertEqual(try transaction.validated().writes.map(\.offset), [0x1000, 0x2100])
        XCTAssertEqual(try transaction.validated().writes.map(\.bytes.count), [0x30, 0x100])
    }

    /// The test that matters: apply it, read the image again, and the new
    /// microcode is in the table with nothing wrong with it.
    func testAnAddedMicrocodeReadsBackAsAnEntry() throws {
        let bytes = image()
        let component = TestFIT.microcode(signature: 0x000906EA, revision: 0xB4, totalSize: 0x100)
        let found = try placement(bytes).get()
        let transaction = try FITEditor.addMicrocode(
            component, at: found, to: try table(bytes), in: ImageReader(bytes)
        ).get()

        let edited = try applying(transaction, to: bytes)
        let report = FITReader.read(ImageReader(edited), image: nil)

        XCTAssertEqual(report.table?.entries.count, 2)
        XCTAssertEqual(report.table?.entries.last?.entry.address, 0xFFFF_2100)
        XCTAssertEqual(report.table?.entries.last?.entry.type, FIT.microcodeType)
        XCTAssertEqual(report.table?.entries.last?.entry.size, 0)
        XCTAssertTrue(report.table?.checksumIsCorrect ?? false)
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.message))")
    }

    /// A new row goes among the microcode rows, not at the end: a FIT handler
    /// may stop at the first type past the one it wants (§3).
    func testTheNewRowKeepsTheTypeOrder() throws {
        let bytes = image(rows: [
            TestFIT.Row(FIT.microcodeType, target: microcode),
            TestFIT.Row(FIT.startupACMType, target: 0x3000),
            TestFIT.Row(FIT.emptyType, address: 0)
        ])
        let found = try placement(bytes).get()
        let transaction = try FITEditor.addMicrocode(
            TestFIT.microcode(totalSize: 0x100), at: found,
            to: try table(bytes), in: ImageReader(bytes)
        ).get()

        let report = FITReader.read(ImageReader(try applying(transaction, to: bytes)), image: nil)

        XCTAssertEqual(
            report.table?.rows.map(\.entry.type),
            [FIT.headerType, FIT.microcodeType, FIT.microcodeType, FIT.startupACMType]
        )
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.message))")
    }

    /// The safe way in (§9.4): an empty slot is eaten, so the table keeps its
    /// length, its place, and the pointer that leads to it.
    func testAnEmptySlotIsEatenRatherThanGrowingTheTable() throws {
        let bytes = image(rows: [
            TestFIT.Row(FIT.microcodeType, target: microcode),
            TestFIT.Row(FIT.emptyType, address: 0)
        ])
        let before = try table(bytes)
        let found = try placement(bytes).get()
        XCTAssertTrue(found.usesEmptySlot)

        let transaction = try FITEditor.addMicrocode(
            TestFIT.microcode(totalSize: 0x100), at: found, to: before, in: ImageReader(bytes)
        ).get()
        let after = try table(try applying(transaction, to: bytes))

        XCTAssertEqual(after.range, before.range)
        XCTAssertEqual(after.header?.size, before.header?.size)
        XCTAssertFalse(after.rows.contains { $0.entry.isEmptySlot })
    }

    /// With no slot the table grows by one row, which needs the sixteen bytes
    /// after it to be free (§9.1).
    func testWithNoSlotTheTableGrowsByOneRow() throws {
        let bytes = image()
        let found = try placement(bytes).get()
        XCTAssertFalse(found.usesEmptySlot)

        let transaction = try FITEditor.addMicrocode(
            TestFIT.microcode(totalSize: 0x100), at: found,
            to: try table(bytes), in: ImageReader(bytes)
        ).get()
        let after = try table(try applying(transaction, to: bytes))

        XCTAssertEqual(after.header?.size, 3)
        XCTAssertEqual(after.range.count, 3 * 16)
    }

    func testATableWithNoRoomAfterItCannotGrow() throws {
        let bytes = image(contents: [0x1020: [0x11, 0x22, 0x33, 0x44]])
        let found = try placement(bytes).get()

        XCTAssertEqual(
            FITEditor.addMicrocode(
                TestFIT.microcode(totalSize: 0x100), at: found,
                to: try table(bytes), in: ImageReader(bytes)
            ),
            .failure(.theTableCannotGrow)
        )
    }

    // MARK: - Removing

    /// The rows below move up and the sixteen bytes that frees become an empty
    /// slot — the table keeps its length and its place (§10).
    func testRemovingLeavesAnEmptySlotInTheTail() throws {
        let bytes = image(rows: [
            TestFIT.Row(FIT.microcodeType, target: microcode),
            TestFIT.Row(FIT.startupACMType, target: 0x3000)
        ])
        let before = try table(bytes)

        let transaction = try FITEditor.removeEntry(2, from: before, in: ImageReader(bytes)).get()
        let after = try table(try applying(transaction, to: bytes))

        XCTAssertEqual(transaction.name, "Remove FIT Entry")
        XCTAssertEqual(after.range, before.range)
        XCTAssertEqual(after.rows.map(\.entry.type),
                       [FIT.headerType, FIT.microcodeType, FIT.emptyType])
        XCTAssertTrue(after.checksumIsCorrect)
    }

    /// And the component stays where it is: erasing it is the riskier half of
    /// §10 step 5.
    func testRemovingLeavesTheComponentAlone() throws {
        let bytes = image(rows: [
            TestFIT.Row(FIT.microcodeType, target: microcode),
            TestFIT.Row(FIT.microcodeType, target: microcode)
        ])
        let transaction = try FITEditor.removeEntry(
            2, from: try table(bytes), in: ImageReader(bytes)
        ).get()

        let edited = try applying(transaction, to: bytes)

        XCTAssertEqual(
            Array(edited[Int(microcode)..<Int(microcode + 4)]),
            Array(bytes[Int(microcode)..<Int(microcode + 4)])
        )
    }

    func testTheHeaderCannotBeRemoved() throws {
        let bytes = image()

        XCTAssertEqual(
            FITEditor.removeEntry(0, from: try table(bytes), in: ImageReader(bytes)),
            .failure(.cannotRemoveTheHeader)
        )
    }

    /// A table without microcode will not boot the machine it came out of
    /// (§8.7, §10 step 1).
    func testTheLastMicrocodeCannotBeRemoved() throws {
        let bytes = image()

        XCTAssertEqual(
            FITEditor.removeEntry(1, from: try table(bytes), in: ImageReader(bytes)),
            .failure(.cannotRemoveTheLastMicrocode)
        )
    }

    func testARowThatIsNotThereCannotBeRemoved() throws {
        let bytes = image()

        XCTAssertEqual(
            FITEditor.removeEntry(9, from: try table(bytes), in: ImageReader(bytes)),
            .failure(.noSuchEntry)
        )
    }

    /// Add then remove: the table comes back to the rows it started with, and
    /// nothing in the image has changed size.
    func testAddingAndRemovingComeBackToWhereItStarted() throws {
        let bytes = image()
        let found = try placement(bytes).get()
        let added = try applying(
            try FITEditor.addMicrocode(
                TestFIT.microcode(signature: 0x000906EA, totalSize: 0x100), at: found,
                to: try table(bytes), in: ImageReader(bytes)
            ).get(),
            to: bytes
        )
        let grown = try table(added)

        let back = try applying(
            try FITEditor.removeEntry(2, from: grown, in: ImageReader(added)).get(), to: added
        )
        let report = FITReader.read(ImageReader(back), image: nil)

        XCTAssertEqual(back.count, bytes.count)
        XCTAssertEqual(report.table?.rows.map(\.entry.type),
                       [FIT.headerType, FIT.microcodeType, FIT.emptyType])
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.message))")
    }
}
