import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIImage

/// A microcode run that lives inside an FFS file rather than in a raw region.
///
/// Plenty of boards keep it there, and then a change to those bytes leaves the
/// *file's* own checksums describing what used to be in it (§5.4). Putting them
/// right is part of the same edit — a file whose checksum is half-fixed is
/// worse than one that was never touched.
final class FITContainerTests: XCTestCase {
    private let otherFileGUID = FFS.otherFileGUID
    private let firstMicrocode: UInt64 = 0x4060
    private let secondMicrocode: UInt64 = 0x4160

    /// A volume at 0x4000 with one raw FFS file in it, whose body is two
    /// microcodes, and a FIT at 0x1000 that names them.
    private func image() -> [UInt8] {
        // Two microcodes and the slack a vendor leaves after them, which is
        // what a bigger replacement grows into.
        let run = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100)
            + TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
            + [UInt8](repeating: 0xFF, count: 0x200)
        return TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: firstMicrocode),
                TestFIT.Row(FIT.microcodeType, target: secondMicrocode)
            ],
            contents: [0x4000: FFS.volume(holding: FFS.file(body: run))]
        )
    }

    private func parse(_ bytes: [UInt8]) -> UEFIImage {
        UEFIParser.parse(bytes)
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

    private func checksumProblems(in bytes: [UInt8]) -> [UEFIDiagnostic] {
        parse(bytes).diagnostics.filter {
            if case .checksumMismatch = $0.kind { return true }
            return false
        }
    }

    /// The fixture is a valid image to begin with, or the test below proves
    /// nothing.
    func testTheFixtureStartsOutRight() throws {
        let bytes = image()
        let parsed = parse(bytes)

        XCTAssertTrue(checksumProblems(in: bytes).isEmpty,
                      "\(parse(bytes).diagnostics.map(\.message))")
        // The file bounds the run — its body is opaque to the tree, being a raw
        // file, and that is exactly the element a component must not grow past.
        XCTAssertEqual(parsed.innermostNode(containing: firstMicrocode)?.kind, .file)
        let report = FITReader.read(ImageReader(bytes), image: parsed)
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.message))")
        XCTAssertEqual(report.table?.entries.compactMap { row -> UInt64? in
            guard case .microcode(let header) = row.target else { return nil }
            return header.offset
        }, [firstMicrocode, secondMicrocode])
    }

    /// Removing the first microcode moves the second up inside the file's body,
    /// which changes the body — so the file's checksums are recomputed in the
    /// same transaction.
    func testRemovingInsideAFileRepairsThatFilesChecksums() throws {
        let bytes = image()
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)

        let (transaction, outcome) = try FITEditor.removeEntry(
            1, from: table, image: parsed, in: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertTrue(checksumProblems(in: edited).isEmpty,
                      "\(parse(edited).diagnostics.map(\.message))")
        let after = FITReader.read(ImageReader(edited), image: parse(edited))
        XCTAssertEqual(after.table?.entries.map(\.entry.address), [0xFFFF_4060])
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// And so does replacing one with a body of another size.
    func testReplacingInsideAFileRepairsThatFilesChecksums() throws {
        let bytes = image()
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        let bigger = TestFIT.microcode(signature: 0x0008_06EA, revision: 0xF1, totalSize: 0x180)

        let (transaction, outcome) = try FITEditor.addOrReplaceMicrocode(
            bigger, in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertTrue(checksumProblems(in: edited).isEmpty,
                      "\(parse(edited).diagnostics.map(\.message))")
    }

    /// A file without the checksum attribute carries a fixed value in the
    /// field, and which fixed value depends on the *volume's* revision (§5.4).
    /// A change to its body leaves that value right, so the repair has nothing
    /// to write — and must not write the other revision's constant over it.
    func testAFileWithNoBodyChecksumIsLeftAlone() throws {
        let run = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100)
            + TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: firstMicrocode),
                TestFIT.Row(FIT.microcodeType, target: secondMicrocode)
            ],
            contents: [0x4000: FFS.volume(holding: FFS.file(body: run, checksummed: false))]
        )
        let parsed = parse(bytes)
        XCTAssertTrue(checksumProblems(in: bytes).isEmpty,
                      "precondition: \(parse(bytes).diagnostics.map(\.message))")
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)

        let (transaction, _) = try FITEditor.removeEntry(
            1, from: table, image: parsed, in: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)

        XCTAssertTrue(checksumProblems(in: edited).isEmpty,
                      "\(parse(edited).diagnostics.map(\.message))")
    }

    /// The shape a real board has: a raw FFS file holding the microcode run
    /// with no slack left in it, and the volume's own free space directly
    /// behind that file. A new microcode goes into the free space — it is
    /// erased, nothing has claimed it, and it is where a bench reaches.
    func testANewMicrocodeGoesIntoTheVolumesFreeSpace() throws {
        let run = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100)
            + TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: firstMicrocode),
                TestFIT.Row(FIT.microcodeType, target: secondMicrocode)
            ],
            contents: [0x4000: FFS.volume(holding: FFS.file(body: run))]
        )
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        // The file ends right behind the second microcode, so there is nothing
        // free inside it at all.
        XCTAssertEqual(parsed.innermostNode(containing: secondMicrocode)?.range.upperBound,
                       secondMicrocode + 0x100)

        let (transaction, outcome) = try FITEditor.addOrReplaceMicrocode(
            TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x300),
            in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)
        let after = FITReader.read(ImageReader(edited), image: parse(edited))

        XCTAssertEqual(outcome.kind, .added)
        XCTAssertEqual(outcome.range.lowerBound, secondMicrocode + 0x100,
                       "the free space starts where the file ends")
        XCTAssertEqual(outcome.range.lowerBound % 16, 0)
        XCTAssertEqual(after.table?.entries.count, 3)
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
        XCTAssertTrue(checksumProblems(in: edited).isEmpty,
                      "\(parse(edited).diagnostics.map(\.message))")

        // The file grew to cover it, so the component is inside a structure
        // rather than loose in the volume's free space — and the free space
        // shrank by exactly as much, without anything having to record it.
        let tree = parse(edited)
        let file = try XCTUnwrap(tree.innermostNode(containing: outcome.range.lowerBound))
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.range.upperBound, outcome.range.upperBound)
        let free = try XCTUnwrap(tree.allNodes.first { $0.kind == .freeSpace })
        XCTAssertEqual(free.range.lowerBound, outcome.range.upperBound)
        XCTAssertFalse(tree.allNodes.contains { $0.kind == .nonUEFIData },
                       "nothing is left loose in the volume")
    }

    /// With another file behind it there is nothing to grow into, and the free
    /// space beyond that neighbour is not somewhere to drop a component: the
    /// volume's own walk would meet it as a file that is not one. So the
    /// addition is refused rather than leaving a volume full of nonsense.
    func testAFileWithSomethingBehindItIsNotGrown() throws {
        let run = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100)
            + TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
        let neighbour = FFS.file(body: [UInt8](repeating: 0x5A, count: 0x100), guid: otherFileGUID)
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: firstMicrocode),
                TestFIT.Row(FIT.microcodeType, target: secondMicrocode)
            ],
            contents: [0x4000: FFS.volume(holding: FFS.file(body: run) + neighbour)]
        )
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        let fileEnd = try XCTUnwrap(
            parsed.innermostNode(containing: secondMicrocode)?.range.upperBound
        )

        let outcome = FITEditor.addOrReplaceMicrocode(
            TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x100),
            in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        )

        guard case .failure(let problem) = outcome else {
            return XCTFail("expected a refusal rather than a loose component")
        }
        guard case .theRunCannotGrow = problem else {
            return XCTFail("expected the run not to fit, got \(problem)")
        }
        XCTAssertEqual(fileEnd, secondMicrocode + 0x100, "precondition: the file has no slack")
    }

    /// A replacement that outgrows the file grows the file, when the volume's
    /// free space is right behind it — the same move an addition makes, for the
    /// same reason: the run belongs inside a structure.
    func testAReplacementThatOutgrowsTheFileGrowsIt() throws {
        let bytes = image()
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        let fileEnd = try XCTUnwrap(parsed.innermostNode(containing: firstMicrocode)?.range.upperBound)
        let bigger = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x400)

        let (transaction, outcome) = try FITEditor.addOrReplaceMicrocode(
            bigger, in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)
        let tree = parse(edited)

        XCTAssertEqual(outcome.moved, 1)
        let grown = try XCTUnwrap(tree.innermostNode(containing: firstMicrocode))
        XCTAssertEqual(grown.kind, .file)
        XCTAssertGreaterThan(grown.range.upperBound, fileEnd)
        XCTAssertTrue(checksumProblems(in: edited).isEmpty, "\(tree.diagnostics.map(\.message))")
        XCTAssertFalse(tree.allNodes.contains { $0.kind == .nonUEFIData })
        let after = FITReader.read(ImageReader(edited), image: tree)
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// A file padded to its end with something that is not `0xFF` — `0x20` is
    /// what one real board uses — is still a file with room in it. The
    /// specification says nothing about what unused space inside a file has to
    /// contain; §5.8 describes only a volume's free space. What marks filler is
    /// the uniformity, not the byte.
    func testAFilePaddedWithSomethingElseStillHasRoom() throws {
        let bytes = paddedWithSpaces(rows: 1)
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        XCTAssertEqual(parsed.innermostNode(containing: table.range.lowerBound)?.kind, .file)

        let (transaction, outcome) = try FITEditor.addOrReplaceMicrocode(
            TestFIT.microcode(signature: 0x000A_0671, totalSize: 0x100),
            in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)
        let after = FITReader.read(ImageReader(edited), image: parse(edited))

        XCTAssertEqual(outcome.kind, .added)
        XCTAssertEqual(after.table?.header?.size, 3, "the table grew into the padding")
        XCTAssertTrue(after.problems.isEmpty, "\(after.problems.map(\.message))")
    }

    /// And what an edit gives back is filled the same way, so the tail stays
    /// the one uniform stretch the next edit can use.
    func testWhatARemovalGivesBackIsFilledTheWayTheFileIs() throws {
        let bytes = paddedWithSpaces(rows: 2)
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        let tableEnd = table.range.upperBound

        let (transaction, _) = try FITEditor.removeEntry(
            2, from: table, image: parsed, in: ImageReader(bytes), addressDiff: 0xFFFF_0000
        ).get()
        let edited = try applying(transaction, to: bytes)

        XCTAssertEqual(
            Array(edited[Int(tableEnd - 16)..<Int(tableEnd)]),
            [UInt8](repeating: 0x20, count: 16),
            "the row it gave up is padded like the rest of the file"
        )
    }

    /// An image whose FIT table sits inside a second file in the same volume,
    /// that file padded to its end with spaces — which is what one real board
    /// does.
    ///
    /// The volume holds the microcode file with slack of its own and then the
    /// table's file, whose body starts where the first one ends.
    /// The table is written over the front of that body and the rest of it
    /// stays 0x20.
    private func paddedWithSpaces(rows: Int) -> [UInt8] {
        // Exactly as many components as the table names: one the table does not
        // name is a component in the way, and the tool is right to refuse to
        // write over it.
        var run = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100)
        if rows > 1 {
            run += TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
        }
        run += [UInt8](repeating: 0xFF, count: 0x200)
        let spaces = FFS.file(
            body: [UInt8](repeating: 0x20, count: 0x200), guid: otherFileGUID
        )
        var table: [TestFIT.Row] = [TestFIT.Row(FIT.microcodeType, target: firstMicrocode)]
        if rows > 1 { table.append(TestFIT.Row(FIT.microcodeType, target: secondMicrocode)) }
        // 0x48 volume header, 0x18 file header, the run, and 0x18 for the
        // second file's header: where the table's own body begins.
        let tableOffset = 0x4000 + 0x48 + 0x18 + UInt64(run.count) + 0x18
        return TestFIT.image(
            tableOffset: tableOffset,
            rows: table,
            contents: [0x4000: FFS.volume(holding: FFS.file(body: run) + spaces)]
        )
    }

    /// And where the file cannot grow — another file directly behind it — the
    /// replacement is refused rather than written through the neighbour.
    func testAReplacementIsRefusedWhereTheFileCannotGrow() throws {
        let run = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x100)
            + TestFIT.microcode(signature: 0x0009_06EA, totalSize: 0x100)
        let neighbour = FFS.file(body: [UInt8](repeating: 0x5A, count: 0x100), guid: otherFileGUID)
        let bytes = TestFIT.image(
            rows: [
                TestFIT.Row(FIT.microcodeType, target: firstMicrocode),
                TestFIT.Row(FIT.microcodeType, target: secondMicrocode)
            ],
            contents: [0x4000: FFS.volume(holding: FFS.file(body: run) + neighbour)]
        )
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        let bigger = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x200)

        let outcome = FITEditor.addOrReplaceMicrocode(
            bigger, in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        )

        guard case .failure(let problem) = outcome else { return XCTFail("expected a refusal") }
        guard case .theRunCannotGrow = problem else {
            return XCTFail("expected the run not to fit, got \(problem)")
        }
    }
}

/// The smallest volume and file that hold a microcode run.
private enum FFS {
    static let volumeGUID = "8C8CE578-8A3D-4F1C-9935-896185C32DD3"
    static let fileGUID = "AABBCCDD-1122-3344-5566-778899AABBCC"
    static let otherFileGUID = "11223344-5566-7788-99AA-BBCCDDEEFF00"

    /// A raw FFS file with a real body checksum, so an edit to its body has
    /// something to invalidate.
    static func file(
        body: [UInt8], checksummed: Bool = true, guid: String = fileGUID
    ) -> [UInt8] {
        var writer = BinaryWriter()
        writer.guid(EFIGUID(guid)!)
        writer.u8(0)                          // header checksum, below
        // With the attribute set the field is a sum of the body; without it,
        // the fixed value a Revision 2 volume uses (§5.4).
        writer.u8(checksummed ? 0 &- Checksums.sum8(body) : 0xAA)
        writer.u8(0x01)                       // Raw
        writer.u8(checksummed ? 0x40 : 0x00)  // FFS_ATTRIB_CHECKSUM
        writer.u24(UInt32(0x18 + body.count))
        writer.u8(0xF8)                       // State

        var bytes = writer.bytes
        let sum = Checksums.sum8(bytes) &- bytes[0x10] &- bytes[0x11] &- bytes[0x17]
        bytes[0x10] = 0 &- sum
        return bytes + body
    }

    /// A 0x1000-byte FFSv2 volume with one file in it.
    static func volume(holding file: [UInt8], length: UInt64 = 0x1000) -> [UInt8] {
        var header = BinaryWriter()
        header.fill(16, with: 0)
        header.guid(EFIGUID(volumeGUID)!)
        header.u64(length)
        header.u32(0x4856_465F)               // _FVH
        header.u32(0x0000_0800)               // erase polarity 1
        header.u16(0x48)                      // HeaderLength
        header.u16(0)                         // Checksum, below
        header.u16(0)                         // ExtHeaderOffset
        header.u8(0)
        header.u8(2)                          // Revision
        header.u32(1)
        header.u32(UInt32(length))
        header.u32(0)
        header.u32(0)

        var bytes = header.bytes
        let checksum = Checksums.checksum16(bytes) ?? 0
        bytes[0x32] = UInt8(truncatingIfNeeded: checksum)
        bytes[0x33] = UInt8(truncatingIfNeeded: checksum >> 8)

        var volume = BinaryWriter()
        volume.raw(bytes)
        volume.raw(file)
        volume.pad(to: length, with: 0xFF)
        return volume.bytes
    }
}
