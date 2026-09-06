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

        guard case .failure(let problem) = try placement(bytes, image: parsed) else {
            return XCTFail("expected a refusal")
        }
        // The refusal names all three things somebody needs to act on it: how
        // much was wanted, how much was free, and where it looked.
        guard case .noRoomForTheComponent(let needed, let free, let inside) = problem else {
            return XCTFail("expected no room")
        }
        XCTAssertEqual(needed, 0x100)
        XCTAssertEqual(free, 0x80)
        XCTAssertEqual(inside, "Padding at 0x1800–0x2180")
        XCTAssertTrue(problem.message.contains("0x80"), problem.message)
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

    /// The search walks out of the element the run is in and takes the free
    /// space it finds on the way — but not past the flash region, which §9.2
    /// forbids a component to cross. Free space in the next region along is
    /// somebody else's.
    func testTheSearchStopsAtTheRegionBoundary() throws {
        let bytes = image()
        let padding = UEFINode(kind: .padding, name: "Padding", range: 0x1800..<0x2180)
        let region = UEFINode(
            kind: .region, name: "BIOS region",
            header: 0x1000..<0x1000, body: 0x1000..<0x3000, children: [padding]
        )
        let elsewhere = UEFINode(kind: .freeSpace, name: "Free space", range: 0x3000..<0x8000)
        let parsed = UEFIImage(
            size: UInt64(bytes.count), roots: [region, elsewhere], addressDiff: 0xFFFF_0000
        )

        guard case .failure(let problem) = try placement(bytes, image: parsed) else {
            return XCTFail("expected a refusal: the free space is in another region")
        }
        guard case .noRoomForTheComponent(_, _, let inside) = problem else {
            return XCTFail("expected no room")
        }
        XCTAssertEqual(inside, "Padding at 0x1800–0x2180")
    }

    /// Padding with something in it is not spare, whatever it is called.
    func testPaddingThatIsNotErasedIsNotRoom() throws {
        var bytes = image()
        bytes.replaceSubrange(0x2200..<0x2210, with: [UInt8](repeating: 0x5A, count: 0x10))
        let element = UEFINode(kind: .padding, name: "Padding", range: 0x1800..<0x2180)
        // Big enough to hold the component twice over, and not spare: there are
        // bytes in it.
        let used = UEFINode(kind: .padding, name: "Padding", range: 0x2180..<0x2600)
        let free = UEFINode(kind: .freeSpace, name: "Free space", range: 0x2600..<0x3000)
        let volume = UEFINode(
            kind: .volume, name: "FFSv2",
            header: 0x1700..<0x1800, body: 0x1800..<0x3000,
            children: [element, used, free]
        )
        let parsed = UEFIImage(
            size: UInt64(bytes.count), roots: [volume], addressDiff: 0xFFFF_0000
        )

        let found = try placement(bytes, size: 0x200, image: parsed).get()

        XCTAssertEqual(found.range, 0x2600..<0x2800, "the free space, not the padding in use")
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

        // The table grew by a row, so the empty slot is still there behind the
        // rows rather than eaten by the new one.
        XCTAssertEqual(
            report.table?.rows.map(\.entry.type),
            [FIT.headerType, FIT.microcodeType, FIT.microcodeType,
             FIT.startupACMType, FIT.emptyType]
        )
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.message))")
    }

    /// A table with room after it grows by a row and the header's count goes up
    /// with it (§9.2 step 6) — an empty slot further down is left where it is.
    func testTheTableGrowsRatherThanEatingASlot() throws {
        let bytes = image(rows: [
            TestFIT.Row(FIT.microcodeType, target: microcode),
            TestFIT.Row(FIT.emptyType, address: 0)
        ])
        let before = try table(bytes)
        let found = try placement(bytes).get()

        let transaction = try FITEditor.addMicrocode(
            TestFIT.microcode(totalSize: 0x100), at: found, to: before, in: ImageReader(bytes)
        ).get()
        let after = try table(try applying(transaction, to: bytes))

        XCTAssertEqual(after.header?.size, 4)
        XCTAssertEqual(after.range.count, before.range.count + 16)
        XCTAssertTrue(after.rows.contains { $0.entry.isEmptySlot })
    }

    /// With nothing free after the table it cannot grow, and then an empty slot
    /// is what lets the addition happen at all (§9.4).
    func testWithNoRoomToGrowASlotIsEaten() throws {
        let bytes = image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: microcode),
                TestFIT.Row(FIT.emptyType, address: 0)
            ],
            contents: [0x1030: [0x11, 0x22, 0x33, 0x44]]
        )
        let before = try table(bytes)
        let found = try placement(bytes).get()

        let transaction = try FITEditor.addMicrocode(
            TestFIT.microcode(totalSize: 0x100), at: found, to: before, in: ImageReader(bytes)
        ).get()
        let after = try table(try applying(transaction, to: bytes))

        XCTAssertEqual(after.range, before.range, "the table keeps its length and its place")
        XCTAssertEqual(after.header?.size, before.header?.size)
        XCTAssertFalse(after.rows.contains { $0.entry.isEmptySlot }, "the slot was eaten")
    }

    /// With no slot the table grows by one row, which needs the sixteen bytes
    /// after it to be free (§9.1).
    func testWithNoSlotTheTableGrowsByOneRow() throws {
        let bytes = image()
        let found = try placement(bytes).get()

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

    // MARK: - Replacing

    private func addOrReplace(
        _ component: [UInt8], in bytes: [UInt8]
    ) throws -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        FITEditor.addOrReplaceMicrocode(
            component, in: try table(bytes), image: nil, reader: ImageReader(bytes),
            addressDiff: TestFIT.addressDiff(of: UInt64(bytes.count))
        )
    }

    /// The ordinary reason to open this form: a CPUID the table already names
    /// has a newer revision. A second row for the same processor is legal,
    /// wasteful, and not what anybody meant.
    func testANewRevisionOfAKnownCpuidReplacesItWhereItWas() throws {
        let bytes = image()
        let newer = TestFIT.microcode(revision: 0xF1, totalSize: 0x100)

        let (transaction, outcome) = try addOrReplace(newer, in: bytes).get()

        XCTAssertEqual(transaction.name, "Replace Microcode")
        XCTAssertEqual(outcome.kind, .replaced)
        XCTAssertEqual(outcome.range, microcode..<(microcode + 0x100))
        XCTAssertEqual(outcome.entryIndex, 1)
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.replaced?.updateRevision, 0xF0)

        // The same size means nothing behind it moves, so nothing in the table
        // changes and the whole edit is one write of the component. A
        // transaction that wrote the table back unchanged would be an undo step
        // that undoes nothing.
        XCTAssertEqual(try transaction.validated().writes.map(\.offset), [microcode])
        let after = try table(try applying(transaction, to: bytes))
        XCTAssertEqual(after.rows.count, 2)
        XCTAssertTrue(after.checksumIsCorrect)
        guard case .microcode(let now) = after.entries[0].target else {
            return XCTFail("expected microcode")
        }
        XCTAssertEqual(now.updateRevision, 0xF1)
    }

    /// The common case at a bench, in a real run: a revision bump of the same
    /// size. Nothing behind it moves, so nothing in the table changes and the
    /// edit is one write — a transaction that wrote the table back unchanged
    /// would be an undo step that undoes nothing.
    func testASameSizeReplacementInARunMovesNothing() throws {
        let bytes = runOfThree()
        let newer = TestFIT.microcode(signature: 0x0009_06EA, revision: 0xF1, totalSize: 0x100)

        let (transaction, outcome) = try addOrReplace(newer, in: bytes).get()
        let after = FITReader.read(ImageReader(try applying(transaction, to: bytes)), image: nil)

        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(try transaction.validated().writes.map(\.offset), [0x2100])
        XCTAssertEqual(after.table?.entries.map(\.entry.address),
                       [0xFFFF_2000, 0xFFFF_2100, 0xFFFF_2200])
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// A bigger one pushes the rest of the run along, and the rows that name
    /// them follow.
    func testABiggerReplacementMovesTheRunAlong() throws {
        let bytes = runOfThree()
        let bigger = TestFIT.microcode(signature: 0x0009_06EA, revision: 0xF1, totalSize: 0x200)

        let (transaction, outcome) = try addOrReplace(bigger, in: bytes).get()
        let edited = try applying(transaction, to: bytes)
        let after = FITReader.read(ImageReader(edited), image: nil)

        XCTAssertEqual(outcome.kind, .replaced)
        XCTAssertEqual(outcome.range, 0x2100..<0x2300)
        XCTAssertEqual(outcome.moved, 1)
        // 0x2000 stays, the replacement fills 0x2100..0x2300, and the third
        // microcode has moved from 0x2200 to 0x2300.
        XCTAssertEqual(after.table?.entries.map(\.entry.address),
                       [0xFFFF_2000, 0xFFFF_2100, 0xFFFF_2300])
        XCTAssertEqual(after.table?.entries.compactMap { row -> UInt32? in
            guard case .microcode(let header) = row.target else { return nil }
            return header.processorSignature
        }, [0x0008_06EA, 0x0009_06EA, 0x000A_0671])
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// And a smaller one pulls it up, so the run stays tight and the free space
    /// stays at the end where the next addition can use it.
    func testASmallerReplacementPullsTheRunUp() throws {
        let bytes = runOfThree()
        let smaller = TestFIT.microcode(signature: 0x0009_06EA, revision: 0xF1, totalSize: 0x80)

        let (transaction, outcome) = try addOrReplace(smaller, in: bytes).get()
        let edited = try applying(transaction, to: bytes)
        let after = FITReader.read(ImageReader(edited), image: nil)

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(after.table?.entries.map(\.entry.address),
                       [0xFFFF_2000, 0xFFFF_2100, 0xFFFF_2180])
        XCTAssertEqual(
            Array(edited[0x2280..<0x2300]), [UInt8](repeating: 0xFF, count: 0x80),
            "the bytes the run gave up are erased"
        )
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// Growing is bounded by whatever element holds the run: a component that
    /// would push the last one past the end of its padding is refused rather
    /// than written over the next structure along.
    func testAReplacementThatWouldLeaveTheElementIsRefused() throws {
        let bytes = runOfThree()
        let padding = UEFINode(kind: .padding, name: "Padding", range: 0x1800..<0x2400)
        let parsed = UEFIImage(size: UInt64(bytes.count), roots: [padding], addressDiff: 0xFFFF_0000)
        let bigger = TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x400)

        let outcome = FITEditor.addOrReplaceMicrocode(
            bigger, in: try table(bytes), image: parsed, reader: ImageReader(bytes),
            addressDiff: TestFIT.addressDiff(of: UInt64(bytes.count))
        )

        guard case .failure(let problem) = outcome else { return XCTFail("expected a refusal") }
        // 0x300: the replacement is 0x300 longer than what it replaces, and the
        // component behind it has to move by the same amount.
        XCTAssertEqual(problem, .theRunCannotGrow(needed: 0x300))
    }

    /// And by what is actually free: bytes belonging to something else are not
    /// room, whatever the element's bounds say.
    func testAReplacementThatWouldWriteOverSomethingIsRefused() throws {
        var bytes = runOfThree()
        bytes.replaceSubrange(0x2300..<0x2310, with: [UInt8](repeating: 0x5A, count: 0x10))
        let bigger = TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x200)

        guard case .failure(let problem) = try addOrReplace(bigger, in: bytes) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(problem, .theRunCannotGrow(needed: 0x100))
    }

    /// A CPUID the table does not name is added, not replaced.
    func testAnUnknownCpuidIsAdded() throws {
        let bytes = image()
        let other = TestFIT.microcode(signature: 0x000906EA, totalSize: 0x100)

        let (transaction, outcome) = try addOrReplace(other, in: bytes).get()

        XCTAssertEqual(transaction.name, "Add Microcode")
        XCTAssertEqual(outcome.kind, .added)
        XCTAssertEqual(outcome.range, 0x2100..<0x2200)
        XCTAssertEqual(try table(try applying(transaction, to: bytes)).entries.count, 2)
    }

    /// One CPUID can have a row per platform mask, and they are not
    /// interchangeable: a microcode for one platform does not belong in the row
    /// that names another's.
    func testTheRowForTheMatchingPlatformIsTheOneReplaced() throws {
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: microcode),
                TestFIT.Row(FIT.microcodeType, target: 0x3000)
            ],
            contents: [
                microcode: TestFIT.microcode(revision: 0xF0, totalSize: 0x100, platformIDs: 0x02),
                0x3000: TestFIT.microcode(revision: 0xEC, totalSize: 0x100, platformIDs: 0x22)
            ]
        )
        let newer = TestFIT.microcode(revision: 0xF1, totalSize: 0x100, platformIDs: 0x22)

        let (_, outcome) = try addOrReplace(newer, in: bytes).get()

        XCTAssertEqual(outcome.kind, .replaced)
        XCTAssertEqual(outcome.entryIndex, 2)
        XCTAssertEqual(outcome.range.lowerBound, 0x3000)
    }

    func testAFileThatIsNotMicrocodeIsRefusedBeforeAnythingIsPlanned() throws {
        guard case .failure(let problem) =
            try addOrReplace([UInt8](repeating: 0x5A, count: 0x100), in: image())
        else { return XCTFail("expected a refusal") }

        XCTAssertEqual(problem, .notMicrocode)
    }

    // MARK: - Removing

    /// Three microcodes in a run, one row each.
    private func runOfThree() -> [UInt8] {
        TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: 0x2000),
                TestFIT.Row(FIT.microcodeType, target: 0x2100),
                TestFIT.Row(FIT.microcodeType, target: 0x2200)
            ],
            contents: [
                0x2000: TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100),
                0x2100: TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100),
                0x2200: TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x100)
            ]
        )
    }

    private func remove(
        _ index: Int, from bytes: [UInt8]
    ) throws -> Result<(ToolTransaction, FITRemovalOutcome), FITEditProblem> {
        FITEditor.removeEntry(
            index, from: try table(bytes), image: nil, in: ImageReader(bytes),
            addressDiff: TestFIT.addressDiff(of: UInt64(bytes.count))
        )
    }

    /// A microcode run is one block, and a hole in the middle of it is not what
    /// a bench wants back: the body goes, what follows moves up into the space,
    /// and the rows that name it follow.
    func testRemovingAMicrocodeClosesUpTheRun() throws {
        let bytes = runOfThree()

        let (transaction, outcome) = try remove(2, from: bytes).get()
        let edited = try applying(transaction, to: bytes)
        let after = FITReader.read(ImageReader(edited), image: nil)

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(outcome.erased, 0x2200..<0x2300)
        // Two rows left, both pointing at a run with no hole in it.
        XCTAssertEqual(after.table?.entries.map(\.entry.address), [0xFFFF_2000, 0xFFFF_2100])
        XCTAssertEqual(after.table?.entries.compactMap { row -> UInt32? in
            guard case .microcode(let header) = row.target else { return nil }
            return header.processorSignature
        }, [0x0008_06EA, 0x000A_0671])
        XCTAssertEqual(
            Array(edited[0x2200..<0x2300]), [UInt8](repeating: 0xFF, count: 0x100),
            "the bytes the move freed are erased"
        )
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// The header's count comes down with the row, and the sixteen bytes the
    /// table gives up are erased behind it (§10 step 3).
    func testRemovingBringsTheCountDownAndErasesTheTail() throws {
        let bytes = runOfThree()
        let before = try table(bytes)

        let (transaction, _) = try remove(2, from: bytes).get()
        let edited = try applying(transaction, to: bytes)
        let after = try table(edited)

        XCTAssertEqual(before.header?.size, 4)
        XCTAssertEqual(after.header?.size, 3)
        XCTAssertEqual(after.range.count, 3 * 16)
        XCTAssertTrue(after.checksumIsCorrect)
        XCTAssertEqual(
            Array(edited[Int(before.range.upperBound - 16)..<Int(before.range.upperBound)]),
            [UInt8](repeating: 0xFF, count: 16)
        )
    }

    /// The last one in the run has nothing after it to move.
    func testRemovingTheLastOfTheRunJustErasesIt() throws {
        let bytes = runOfThree()

        let (transaction, outcome) = try remove(3, from: bytes).get()
        let edited = try applying(transaction, to: bytes)

        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.erased, 0x2200..<0x2300)
        XCTAssertEqual(Array(edited[0x2200..<0x2300]), [UInt8](repeating: 0xFF, count: 0x100))
        XCTAssertEqual(Array(edited[0x2000..<0x2004]), Array(bytes[0x2000..<0x2004]))
        XCTAssertTrue(FITReader.read(ImageReader(edited), image: nil).problems.isEmpty)
    }

    /// A component with anything but erase bytes in front of it is not part of
    /// this run, and the compaction stops rather than writing over whatever
    /// that is.
    func testCompactionStopsAtWhatIsNotErased() throws {
        // Something of somebody else's between the second microcode and the
        // third.
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: 0x2000),
                TestFIT.Row(FIT.microcodeType, target: 0x2100),
                TestFIT.Row(FIT.microcodeType, target: 0x2300)
            ],
            contents: [
                0x2000: TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100),
                0x2100: TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100),
                0x2200: [UInt8](repeating: 0x5A, count: 0x10),
                0x2300: TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x100)
            ]
        )

        let (transaction, outcome) = try remove(2, from: bytes).get()
        let edited = try applying(transaction, to: bytes)
        let after = FITReader.read(ImageReader(edited), image: nil)

        XCTAssertEqual(outcome.moved, 0, "the third does not move")
        XCTAssertEqual(Array(edited[0x2200..<0x2210]), [UInt8](repeating: 0x5A, count: 0x10),
                       "and the bytes in the way are untouched")
        XCTAssertEqual(after.table?.entries.map(\.entry.address), [0xFFFF_2000, 0xFFFF_2300])
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// Every FIT address is aligned to sixteen (§8.9), so a component whose
    /// size is not a multiple of it leaves a gap in front of the next one —
    /// after the move as much as before it.
    func testWhatMovesUpStaysAlignedToSixteen() throws {
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: 0x2000),
                TestFIT.Row(FIT.microcodeType, target: 0x2110),
                TestFIT.Row(FIT.microcodeType, target: 0x2220)
            ],
            contents: [
                0x2000: TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x108),
                0x2110: TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x108),
                0x2220: TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x108)
            ]
        )

        let (transaction, outcome) = try remove(2, from: bytes).get()
        let after = FITReader.read(ImageReader(try applying(transaction, to: bytes)), image: nil)

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(after.table?.entries.map(\.entry.address), [0xFFFF_2000, 0xFFFF_2110])
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// The extent of anything else a row can point at — an ACM, a policy — is
    /// not something this tool knows, so only the row goes.
    func testRemovingARowThatIsNotMicrocodeLeavesTheBytesAlone() throws {
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: microcode),
                TestFIT.Row(FIT.startupACMType, target: 0x3000)
            ],
            contents: [
                microcode: TestFIT.microcode(totalSize: 0x100),
                0x3000: [UInt8](repeating: 0x5A, count: 0x40)
            ]
        )

        let (transaction, outcome) = try remove(2, from: bytes).get()
        let edited = try applying(transaction, to: bytes)

        XCTAssertEqual(outcome.moved, 0)
        XCTAssertNil(outcome.erased)
        XCTAssertEqual(try transaction.validated().writes.count, 1, "the table, and nothing else")
        XCTAssertEqual(Array(edited[0x3000..<0x3040]), [UInt8](repeating: 0x5A, count: 0x40))
        XCTAssertEqual(try table(edited).entries.count, 1)
    }

    func testTheHeaderCannotBeRemoved() throws {
        guard case .failure(let problem) = try remove(0, from: image()) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(problem, .cannotRemoveTheHeader)
    }

    /// A table without microcode will not boot the machine it came out of
    /// (§8.7, §10 step 1).
    func testTheLastMicrocodeCannotBeRemoved() throws {
        guard case .failure(let problem) = try remove(1, from: image()) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(problem, .cannotRemoveTheLastMicrocode)
    }

    func testARowThatIsNotThereCannotBeRemoved() throws {
        guard case .failure(let problem) = try remove(9, from: image()) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(problem, .noSuchEntry)
    }

    /// Add then remove: the table and the run both come back to what they were,
    /// and the file has not changed size.
    func testAddingAndRemovingComeBackToWhereItStarted() throws {
        let bytes = image()
        let found = try placement(bytes).get()
        let added = try applying(
            try FITEditor.addMicrocode(
                TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100), at: found,
                to: try table(bytes), in: ImageReader(bytes)
            ).get(),
            to: bytes
        )
        XCTAssertEqual(try table(added).header?.size, 3)

        let (transaction, _) = try remove(2, from: added).get()
        let back = try applying(transaction, to: added)
        let report = FITReader.read(ImageReader(back), image: nil)

        XCTAssertEqual(back.count, bytes.count)
        XCTAssertEqual(back, bytes, "byte for byte what it was")
        XCTAssertEqual(report.table?.header?.size, 2)
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.message))")
    }
}
