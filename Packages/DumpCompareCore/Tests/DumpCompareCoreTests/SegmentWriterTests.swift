import Foundation
import XCTest
@testable import DumpCompareCore

/// §21.5 the segment writer: a partition written out as its pieces, all or
/// nothing. The source is a `ByteStorage` (the document's storage, which reads
/// the current edited bytes), and the parts are the partition's ranges. The
/// writer is synchronous and chunked, so the tests drive it directly and force
/// failures and cancels through the `shouldCancel` seam and a throwing source.
final class SegmentWriterTests: XCTestCase {
    /// A temp directory for the writer's output, removed when the test ends.
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A file's bytes, or nil when it does not exist.
    private func read(_ url: URL) -> Data? {
        (try? Data(contentsOf: url))
    }

    /// The published (non-hidden) file names in `directory`, sorted.
    private func publishedFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Every entry in `directory`, including the hidden `.name.dc-*.tmp` temps.
    private func allEntries(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A file the sandboxed app has been granted but whose directory it cannot
    /// write: the shape that forces the direct-write fallback, because the
    /// sibling temp cannot be created. Returns the target and asserts both halves
    /// of the premise — the temp really cannot be created, the file really is
    /// still writable.
    private func makeTargetInAnUnwritableDirectory(_ initial: Data) throws -> URL {
        let directory = try makeTempDirectory()
        let target = directory.appendingPathComponent("piece.bin")
        try initial.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertFalse(FileManager.default.createFile(
            atPath: directory.appendingPathComponent(".probe.tmp").path, contents: nil),
            "the sibling temp file really cannot be created")
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: target.path),
                      "the chosen file really is still writable")
        return target
    }

    // MARK: - The bytes of each part

    /// Each part is written to its own file holding exactly the source's bytes
    /// for that part's range — the partition written out as its pieces.
    func testEachPartHoldsItsOwnBytes() throws {
        // 0..16: 00 01 02 … 0F. Two parts: [0,8) and [8,16).
        let source = ArrayStorage([UInt8](0..<16))
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<8, name: "S0.bin"),
             SegmentWriter.Part(range: 8..<16, name: "S1.bin")],
            from: source, to: directory
        )

        XCTAssertEqual(read(directory.appendingPathComponent("S0.bin")),
                       Data([UInt8](0..<8)), "S0 holds bytes [0,8)")
        XCTAssertEqual(read(directory.appendingPathComponent("S1.bin")),
                       Data([UInt8](8..<16)), "S1 holds bytes [8,16)")
        XCTAssertEqual(try publishedFiles(in: directory), ["S0.bin", "S1.bin"])
    }

    // MARK: - A single piece

    /// A single part covering the whole file writes the whole file as one piece.
    func testASinglePieceWritesTheWholeFile() throws {
        let source = ArrayStorage([UInt8](repeating: 0xAB, count: 64))
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<64, name: "whole.bin")],
            from: source, to: directory
        )

        XCTAssertEqual(read(directory.appendingPathComponent("whole.bin")),
                       Data([UInt8](repeating: 0xAB, count: 64)))
        XCTAssertEqual(try publishedFiles(in: directory), ["whole.bin"])
    }

    // MARK: - Overwrite

    /// A part whose name already exists replaces the existing file.
    func testAPartReplacesAnExistingFile() throws {
        let source = ArrayStorage([UInt8](0..<8))
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("S0.bin")
        try Data([UInt8](repeating: 0xFF, count: 8)).write(to: target)

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<8, name: "S0.bin")],
            from: source, to: directory
        )

        XCTAssertEqual(read(target), Data([UInt8](0..<8)), "the existing file is replaced")
    }

    // MARK: - Atomicity: a failure publishes nothing

    /// A source that throws once a read reaches `failAt` — the seam that forces
    /// a failure on a chosen part.
    private struct FailingStorage: ByteStorage {
        let base: ArrayStorage
        let failAt: UInt64
        var size: UInt64 { base.size }
        func read(at offset: UInt64, length: Int) throws -> [UInt8] {
            if offset >= failAt { throw SegmentWriteError.writeFailed }
            return try base.read(at: offset, length: length)
        }
    }

    /// A failure on the last part leaves no published files AND no temporaries —
    /// the directory is exactly as it was.
    func testAFailureOnTheLastPartLeavesNothingBehind() throws {
        // Three parts; the source fails once a read reaches the third part
        // (offset 16). Parts 1 and 2 stage their temps, then part 3's read
        // throws.
        let source = FailingStorage(base: ArrayStorage([UInt8](0..<24)), failAt: 16)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<8, name: "S0.bin"),
             SegmentWriter.Part(range: 8..<16, name: "S1.bin"),
             SegmentWriter.Part(range: 16..<24, name: "S2.bin")],
            from: source, to: directory
        ))

        XCTAssertEqual(try publishedFiles(in: directory), [], "no part is published")
        XCTAssertEqual(try allEntries(in: directory), [], "no temporaries remain")
    }

    // MARK: - Cancellation

    /// A cancel mid-write publishes nothing and leaves no temporaries.
    func testACancelMidWriteLeavesNothingBehind() throws {
        let source = ArrayStorage([UInt8](0..<24))
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Cancel once the first part has written a few bytes: the second part's
        // first chunk sees the cancel and stops.
        var cancelled = false
        var wroteAny = false
        XCTAssertThrowsError(try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<8, name: "S0.bin"),
             SegmentWriter.Part(range: 8..<16, name: "S1.bin"),
             SegmentWriter.Part(range: 16..<24, name: "S2.bin")],
            from: source, to: directory,
            shouldCancel: { cancelled },
            progress: { _ in
                if !wroteAny {
                    wroteAny = true
                    cancelled = true   // cancel after the first chunk
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError, "a cancelled write throws CancellationError")
        }

        XCTAssertEqual(try publishedFiles(in: directory), [], "a cancel publishes nothing")
        XCTAssertEqual(try allEntries(in: directory), [], "a cancel leaves no temporaries")
    }

    // MARK: - A part larger than one chunk

    /// A part bigger than the 1 MiB chunk is streamed in chunks and lands whole
    /// — the path a 16 MB image takes, where no part is ever loaded whole into
    /// RAM. The bytes depend on their absolute offset, so a misaligned or
    /// duplicated chunk would show up as a mismatch.
    func testAPartLargerThanOneChunkIsWrittenWhole() throws {
        let size = 1536 * 1024  // 1.5 MiB: two 1 MiB chunks
        let bytes = (0..<size).map { UInt8($0 % 251) }
        let source = ArrayStorage(bytes)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<UInt64(size), name: "big.bin")],
            from: source, to: directory
        )

        let written = read(directory.appendingPathComponent("big.bin"))
        XCTAssertEqual(written?.count, size, "the whole part is written")
        XCTAssertEqual(written, Data(bytes), "every byte lands at its own offset")
    }

    // MARK: - The sandbox fallback: one part into a file whose directory is not writable

    /// The sandbox fallback for Save Segment (§21.5): the app owns the file the
    /// user chose but not the folder around it, so the atomic swap is impossible.
    /// The part must still land, written straight into the target.
    func testASinglePartFallsBackToWritingTheChosenFileDirectly() throws {
        let source = ArrayStorage([UInt8](0..<16))
        let target = try makeTargetInAnUnwritableDirectory(
            Data([UInt8](repeating: 0xFF, count: 8)))

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<16, name: target.lastPathComponent)],
            from: source, to: target.deletingLastPathComponent()
        )

        XCTAssertEqual(read(target), Data([UInt8](0..<16)),
                       "the part lands in the file the user chose")
    }

    /// The direct write truncates: a part shorter than what the chosen file
    /// already held leaves no tail of the older version behind.
    func testTheDirectWriteFallsBackAndTruncates() throws {
        let source = ArrayStorage([UInt8](0..<4))
        let target = try makeTargetInAnUnwritableDirectory(
            Data([UInt8](repeating: 0xEE, count: 8)))

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<4, name: target.lastPathComponent)],
            from: source, to: target.deletingLastPathComponent()
        )

        XCTAssertEqual(read(target), Data([UInt8](0..<4)),
                       "no tail of what the file held before")
    }

    // MARK: - Progress

    /// Progress reports a monotone fraction that ends at 1.0 once every part is
    /// written.
    func testProgressEndsAtOne() throws {
        let source = ArrayStorage([UInt8](0..<16))
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fractions: [Double] = []

        try SegmentWriter.write(
            [SegmentWriter.Part(range: 0..<8, name: "S0.bin"),
             SegmentWriter.Part(range: 8..<16, name: "S1.bin")],
            from: source, to: directory,
            progress: { fractions.append($0) }
        )

        XCTAssertFalse(fractions.isEmpty, "progress is reported")
        XCTAssertEqual(fractions.last, 1.0, "the final report is 1.0")
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "progress is monotone")
        }
    }

    // MARK: - The content shrinking under the write (§21.5)

    /// A read that comes back short means the content shrank under the write —
    /// a base file truncated by another process. Stopping there would fsync the
    /// temp and rename it into place, publishing a TRUNCATED piece and reporting
    /// the write as done; a 3 MiB part came out 1 MiB with no error at all. The
    /// write must fail instead, and publish nothing.
    func testAShortReadFailsTheWriteInsteadOfPublishingATruncatedPart() throws {
        let size = UInt64(3 * SegmentWriter.chunkSize)
        let source = ShrinkingStorage(size: size, shrinksOnRead: 2)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try SegmentWriter.write([SegmentWriter.Part(range: 0..<size, name: "S0.bin")],
                                    from: source, to: directory)
        ) { error in
            XCTAssertEqual(error as? StorageError, .readFailed)
        }

        let published = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(published, [], "a failed write publishes nothing")
    }

    // MARK: - Cancellation stops at the commit (§21.5)

    /// Cancellation belongs to the staging phase: it publishes nothing, so
    /// stopping there is free. Once every part is a complete temp the renames
    /// run to the end — a rename already made cannot be taken back, and polling
    /// cancel between them published a PREFIX of the set while reporting a
    /// cancelled write (with three parts, cancelling on the second rename left
    /// the first one on disk).
    func testCancellingCannotPublishAPrefixOfTheParts() throws {
        let source = ArrayStorage([UInt8](repeating: 0x11, count: 32))
        let parts = [
            SegmentWriter.Part(range: 0..<8, name: "S0.bin"),
            SegmentWriter.Part(range: 8..<16, name: "S1.bin"),
            SegmentWriter.Part(range: 16..<32, name: "S2.bin"),
        ]

        // How many times does an uncancelled write poll? The last polls belong
        // to the staging phase; anything after it is the commit.
        let counting = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: counting) }
        var polls = 0
        try SegmentWriter.write(parts, from: source, to: counting,
                                shouldCancel: { polls += 1; return false })
        XCTAssertGreaterThan(polls, 0, "the write does poll for cancellation")

        // Say "cancel" from every poll onwards, starting one before the end and
        // walking back: whatever the phase, the directory is all or nothing.
        for threshold in stride(from: polls, through: 1, by: -1) {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var seen = 0
            try? SegmentWriter.write(parts, from: source, to: directory,
                                     shouldCancel: { seen += 1; return seen >= threshold })
            let published = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }
                .sorted()
            XCTAssertTrue(published.isEmpty || published == ["S0.bin", "S1.bin", "S2.bin"],
                          "cancelling at poll \(threshold) left \(published)")
        }
    }
}
