import XCTest
@testable import FITTool
import ToolModuleKit
import UEFIFormat

/// A microcode run that lives inside an FFS file rather than in a raw region.
///
/// Plenty of boards keep it there, and then a change to those bytes leaves the
/// *file's* own checksums describing what used to be in it (§5.4). Putting them
/// right is part of the same edit — a file whose checksum is half-fixed is
/// worse than one that was never touched.
final class FITContainerTests: XCTestCase {
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

    /// The file bounds the run: a replacement that would push the last
    /// microcode past the end of the file it lives in is refused, whatever is
    /// erased beyond it.
    func testTheFileBoundsHowFarTheRunCanGrow() throws {
        let bytes = image()
        let parsed = parse(bytes)
        let table = try XCTUnwrap(FITReader.read(ImageReader(bytes), image: parsed).table)
        let huge = TestFIT.microcode(signature: 0x0008_06EA, totalSize: 0x400)

        let outcome = FITEditor.addOrReplaceMicrocode(
            huge, in: table, image: parsed, reader: ImageReader(bytes), addressDiff: 0xFFFF_0000
        )

        guard case .failure(let problem) = outcome else { return XCTFail("expected a refusal") }
        XCTAssertEqual(problem, .theRunCannotGrow(needed: 0x300))
    }
}

/// The smallest volume and file that hold a microcode run.
private enum FFS {
    static let volumeGUID = "8C8CE578-8A3D-4F1C-9935-896185C32DD3"
    static let fileGUID = "AABBCCDD-1122-3344-5566-778899AABBCC"

    /// A raw FFS file with a real body checksum, so an edit to its body has
    /// something to invalidate.
    static func file(body: [UInt8], checksummed: Bool = true) -> [UInt8] {
        var writer = BinaryWriter()
        writer.guid(EFIGUID(fileGUID)!)
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
