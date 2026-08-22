import XCTest
@testable import DumpCompareCore

final class DiffEngineTests: XCTestCase {
    private typealias Block = DiffBlock

    private func blocks(_ left: [UInt8], _ right: [UInt8]) -> [DiffBlock] {
        DiffEngine.blocks(left: left, right: right)
    }

    private func index(_ left: [UInt8], _ right: [UInt8], chunkSize: Int = DiffEngine.defaultChunkSize) throws -> DiffBlockIndex {
        try DiffEngine.scan(left: ArrayStorage(left), right: ArrayStorage(right), chunkSize: chunkSize)
    }

    // MARK: - Block construction

    /// `blocks(left:right:)` is the byte-at-a-time reference implementation:
    /// maximal runs of same/different at absolute offsets, with the tail only one
    /// file has folded into a difference block. Every boundary in one place —
    /// empty files, a run of one byte, alternating runs, and an EOF-only tail
    /// both alone and touching a difference.
    func testBlockConstruction() {
        let cases: [(name: String, left: [UInt8], right: [UInt8], expected: [Block])] = [
            ("identical files are one same block",
             [0x01, 0x02, 0x03], [0x01, 0x02, 0x03],
             [Block(kind: .same, range: 0..<3)]),
            ("every byte differing is one different block",
             [0x01, 0x02, 0x03], [0xFF, 0xFE, 0xFD],
             [Block(kind: .different, range: 0..<3)]),
            ("a single differing byte",
             [0xAA, 0x00, 0xAA], [0xAA, 0x01, 0xAA],
             [Block(kind: .same, range: 0..<1),
              Block(kind: .different, range: 1..<2),
              Block(kind: .same, range: 2..<3)]),
            ("alternating single bytes",
             [0x00, 0x00, 0x00, 0x00], [0x01, 0x00, 0x01, 0x00],
             [Block(kind: .different, range: 0..<1),
              Block(kind: .same, range: 1..<2),
              Block(kind: .different, range: 2..<3),
              Block(kind: .same, range: 3..<4)]),
            ("an empty left file",
             [], [1, 2, 3],
             [Block(kind: .different, range: 0..<3)]),
            ("an empty right file",
             [1, 2, 3], [],
             [Block(kind: .different, range: 0..<3)]),
            ("two empty files have no blocks",
             [], [],
             []),
            ("an EOF-only tail on the right",
             [0x00, 0x01], [0x00, 0x01, 0xAA],
             [Block(kind: .same, range: 0..<2),
              Block(kind: .different, range: 2..<3)]),
            ("an EOF-only tail on the left",
             [0x00, 0x01, 0xAA], [0x00, 0x01],
             [Block(kind: .same, range: 0..<2),
              Block(kind: .different, range: 2..<3)]),
            // Byte 1 differs and the tail is EOF-only → one different block [1, 4).
            ("an EOF-only tail merges with an adjacent difference",
             [0x00, 0x00, 0x01, 0x02], [0x00, 0xFF],
             [Block(kind: .same, range: 0..<1),
              Block(kind: .different, range: 1..<4)]),
        ]
        for testCase in cases {
            XCTAssertEqual(blocks(testCase.left, testCase.right), testCase.expected, testCase.name)
        }
    }

    // MARK: - Chunked scan

    func testDifferenceSpanningChunkBoundary() throws {
        // Differing byte sits exactly at a chunk boundary (index 3, chunk size 3).
        let left = [UInt8]([0, 1, 2, 3, 4, 5])
        let right = [UInt8]([0, 1, 2, 9, 4, 5])
        let scanned = try index(left, right, chunkSize: 3)
        XCTAssertEqual(scanned.blocks, [
            Block(kind: .same, range: 0..<3),
            Block(kind: .different, range: 3..<4),
            Block(kind: .same, range: 4..<6),
        ])
    }

    func testScanCancellationThrows() throws {
        var checks = 0
        XCTAssertThrowsError(try DiffEngine.scan(
            left: ArrayStorage([UInt8](repeating: 0, count: 8)),
            right: ArrayStorage([UInt8](repeating: 1, count: 8)),
            chunkSize: 2,
            shouldCancel: {
                checks += 1
                return checks > 1
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testScanReportsProgressReachingOne() throws {
        var last: Double = -1
        let index = try DiffEngine.scan(
            left: ArrayStorage([UInt8](repeating: 0, count: 16)),
            right: ArrayStorage([UInt8](repeating: 0, count: 16)),
            chunkSize: 3,
            progress: { last = max(last, $0) }
        )
        XCTAssertEqual(last, 1.0)
        XCTAssertEqual(index.blocks, [Block(kind: .same, range: 0..<16)])
    }

    // MARK: - Index lookup & navigation

    func testStateAt() throws {
        let index = try self.index([0x00, 0x01, 0x02], [0x00, 0xFF, 0x02])
        XCTAssertEqual(index.state(at: 0), .same)
        XCTAssertEqual(index.state(at: 1), .different)
        XCTAssertEqual(index.state(at: 2), .same)
        XCTAssertNil(index.state(at: 3))   // past EOF
    }

    func testDifferenceAndSameBlocks() throws {
        let index = try self.index([0x00, 0x00, 0x01, 0x00, 0x00], [0x00, 0x00, 0xFF, 0x00, 0x00])
        XCTAssertEqual(index.differenceBlocks, [Block(kind: .different, range: 2..<3)])
        XCTAssertEqual(index.sameBlocks, [
            Block(kind: .same, range: 0..<2),
            Block(kind: .same, range: 3..<5),
        ])
    }

    func testNavigation() throws {
        // Blocks: same[0,2) diff[2,4) same[4,6) diff[6,8)
        let left = [UInt8]([0, 0, 1, 1, 2, 2, 3, 3])
        let right = [UInt8]([0, 0, 9, 9, 2, 2, 8, 8])
        let index = try self.index(left, right)

        XCTAssertEqual(index.firstBlock(after: 1)?.range, 2..<4)
        XCTAssertEqual(index.firstBlock(after: 3)?.range, 4..<6)
        XCTAssertNil(index.firstBlock(after: 7))
        XCTAssertEqual(index.firstBlock(before: 4)?.range, 2..<4)
        XCTAssertEqual(index.firstBlock(before: 2)?.range, 0..<2)
        XCTAssertNil(index.firstBlock(before: 0))

        // Strictly-after for "next".
        XCTAssertEqual(index.nextDifference(from: 0)?.range, 2..<4)
        XCTAssertEqual(index.nextDifference(from: 2)?.range, 6..<8)  // skips current block
        XCTAssertEqual(index.nextDifference(from: 7)?.range, nil)
        XCTAssertEqual(index.nextSame(from: 1)?.range, 4..<6)
        XCTAssertNil(index.nextSame(from: 4))

        // At-or-before for "previous".
        XCTAssertEqual(index.previousDifference(from: 4)?.range, 2..<4)
        XCTAssertEqual(index.previousDifference(from: 6)?.range, 2..<4)
        XCTAssertEqual(index.previousDifference(from: 8)?.range, 6..<8)
        XCTAssertNil(index.previousDifference(from: 1))
        XCTAssertEqual(index.previousSame(from: 7)?.range, 4..<6)
        XCTAssertNil(index.previousSame(from: 1))
    }

    func testNavigationIncludesEOFOnlyBlocks() throws {
        let index = try self.index([0x00, 0x01], [0x00, 0x01, 0xAA, 0xBB])
        XCTAssertEqual(index.nextDifference(from: 0)?.range, 2..<4)
        XCTAssertEqual(index.previousDifference(from: 4)?.range, 2..<4)
    }

    /// Two very different large files produce one block per byte — millions of
    /// blocks. The navigation queries must stay O(log n) via binary search, not
    /// re-scan the array from an end: a linear scan here is exactly what froze
    /// drag selection once indexing completed. Pins the large-array semantics at
    /// the extremes and the middle.
    func testNavigationQueriesScaleToManyBlocks() {
        let count = 200_000
        var blocks: [DiffBlock] = []
        blocks.reserveCapacity(count)
        for i in 0..<count {
            let kind: DiffBlock.Kind = (i % 2 == 0) ? .same : .different
            blocks.append(Block(kind: kind, range: UInt64(i)..<UInt64(i + 1)))
        }
        let index = DiffBlockIndex(leftSize: UInt64(count), rightSize: UInt64(count), blocks: blocks)

        XCTAssertEqual(index.nextDifference(from: 0)?.range, 1..<2)
        XCTAssertEqual(index.nextDifference(from: 2)?.range, 3..<4)
        XCTAssertEqual(index.nextDifference(from: 123_456)?.range, 123_457..<123_458)
        XCTAssertNil(index.nextDifference(from: UInt64(count) - 1))

        XCTAssertEqual(index.previousDifference(from: 4)?.range, 3..<4)
        XCTAssertEqual(index.previousDifference(from: UInt64(count))?.range, UInt64(count - 1)..<UInt64(count))
        XCTAssertEqual(index.previousDifference(from: 2)?.range, 1..<2)
        XCTAssertNil(index.previousDifference(from: 1))

        XCTAssertEqual(index.nextSame(from: 0)?.range, 2..<3)
        XCTAssertEqual(index.nextSame(from: 1)?.range, 2..<3)
        XCTAssertNil(index.nextSame(from: UInt64(count) - 1))

        XCTAssertEqual(index.previousSame(from: 1)?.range, 0..<1)
        XCTAssertEqual(index.previousSame(from: UInt64(count))?.range, UInt64(count - 2)..<UInt64(count - 1))
        XCTAssertNil(index.previousSame(from: 0))
    }

    // MARK: - Incremental invalidation

    /// An overwrite recomputes only its own range and splices it back, so the
    /// result must be the blocks a full rescan of the edited file produces — in
    /// both directions (same becoming different and back), and where the write
    /// runs past the old EOF or starts past it.
    func testApplyOverwrite() throws {
        let cases: [(name: String, baseLeft: [UInt8], right: [UInt8], editedLeft: [UInt8],
                     range: Range<UInt64>, chunkSize: Int, expected: [Block])] = [
            ("same becomes different",
             [0x01, 0x02, 0x03, 0x04], [0x01, 0x02, 0x03, 0x04], [0x01, 0xFF, 0x03, 0x04],
             1..<2, 2,
             [Block(kind: .same, range: 0..<1),
              Block(kind: .different, range: 1..<2),
              Block(kind: .same, range: 2..<4)]),
            ("different becomes same",
             [0x01, 0xFF, 0x03, 0x04], [0x01, 0x02, 0x03, 0x04], [0x01, 0x02, 0x03, 0x04],
             1..<2, DiffEngine.defaultChunkSize,
             [Block(kind: .same, range: 0..<4)]),
            ("a write extending past EOF",
             [0x01, 0x02], [0x01, 0x02], [0x01, 0x03, 0x04],
             1..<3, DiffEngine.defaultChunkSize,
             [Block(kind: .same, range: 0..<1),
              Block(kind: .different, range: 1..<3)]),
            ("a write entirely past EOF, from two empty files",
             [], [], [0xAA, 0xBB, 0xCC],
             2..<5, DiffEngine.defaultChunkSize,
             [Block(kind: .different, range: 0..<3)]),
        ]
        for testCase in cases {
            let right = ArrayStorage(testCase.right)
            let base = try DiffEngine.scan(left: ArrayStorage(testCase.baseLeft), right: right,
                                           chunkSize: testCase.chunkSize)
            let edited = ArrayStorage(testCase.editedLeft)
            let updated = try DiffEngine.apply(.overwrite(range: testCase.range), to: base,
                                               left: edited, right: right, chunkSize: testCase.chunkSize)
            XCTAssertEqual(updated.blocks, testCase.expected, testCase.name)
            XCTAssertEqual(updated, try DiffEngine.scan(left: edited, right: right,
                                                        chunkSize: testCase.chunkSize),
                           "\(testCase.name): must equal a full rescan")
        }
    }

    func testApplyInsertShiftsOffsets() throws {
        let left = ArrayStorage([0x01, 0x02, 0x03, 0x04, 0x05])
        let right = ArrayStorage([0x01, 0x02, 0x03, 0x04])
        let base = try DiffEngine.scan(left: left, right: right)
        XCTAssertEqual(base.blocks, [
            Block(kind: .same, range: 0..<4),
            Block(kind: .different, range: 4..<5),
        ])

        let inserted = ArrayStorage([0x01, 0x02, 0xAA, 0xBB, 0x03, 0x04, 0x05])
        let updated = try DiffEngine.apply(.insert(at: 2, length: 2), to: base, left: inserted, right: right)
        let expected = try DiffEngine.scan(left: inserted, right: right)
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(updated.blocks, [
            Block(kind: .same, range: 0..<2),
            Block(kind: .different, range: 2..<7),
        ])
    }

    func testApplyDeleteShiftsOffsets() throws {
        let left = ArrayStorage([0x01, 0x02, 0x03, 0x04])
        let right = ArrayStorage([0x01, 0x0A, 0x03, 0x04])
        let base = try DiffEngine.scan(left: left, right: right)
        XCTAssertEqual(base.blocks, [
            Block(kind: .same, range: 0..<1),
            Block(kind: .different, range: 1..<2),
            Block(kind: .same, range: 2..<4),
        ])

        let deleted = ArrayStorage([0x01, 0x03, 0x04])
        let updated = try DiffEngine.apply(.delete(range: 1..<2), to: base, left: deleted, right: right)
        let expected = try DiffEngine.scan(left: deleted, right: right)
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(updated.blocks, [
            Block(kind: .same, range: 0..<1),
            Block(kind: .different, range: 1..<4),
        ])
    }

    func testApplyMatchesFreshScanForMutations() throws {
        // Cross-check several edit shapes against a full rescan.
        let right = ArrayStorage([0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
        let edits: [(DiffEdit, [UInt8])] = [
            (.overwrite(range: 2..<4), [0x0A, 0x0B, 0xFF, 0xFE, 0x0E, 0x0F]),
            (.overwrite(range: 0..<6), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
            (.insert(at: 3, length: 1), [0x0A, 0x0B, 0x0C, 0x99, 0x0D, 0x0E, 0x0F]),
            (.delete(range: 1..<4), [0x0A, 0x0E, 0x0F]),
        ]
        for (edit, newBytes) in edits {
            let base = try DiffEngine.scan(left: ArrayStorage([0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]), right: right, chunkSize: 2)
            let edited = ArrayStorage(newBytes)
            let updated = try DiffEngine.apply(edit, to: base, left: edited, right: right, chunkSize: 2)
            let expected = try DiffEngine.scan(left: edited, right: right, chunkSize: 2)
            XCTAssertEqual(updated, expected, "edit \(edit)")
        }
    }

    // MARK: - Background actor

    func testActorBuildMatchesSyncScan() async throws {
        let builder = DiffIndexBuilder()
        let left = ArrayStorage([0x00, 0x00, 0x01, 0x00, 0x00])
        let right = ArrayStorage([0x00, 0x00, 0x02, 0x00, 0x00])
        let index = try await builder.build(left: left, right: right, chunkSize: 2)
        XCTAssertEqual(index, try DiffEngine.scan(left: left, right: right, chunkSize: 2))
        let progress = await builder.progress
        XCTAssertEqual(progress, 1.0)
    }

    // MARK: - Progress (§8.3, §14.4)

    /// `scanAsync` reports progress per chunk, so the UI's progress bar can move
    /// as the scan covers the file. Deterministic: the `progress` callback fires
    /// on every chunk regardless of timing, so intermediate values are always
    /// present — never just 0 followed by a jump to 1.
    func testScanAsyncReportsProgressIncrementally() async throws {
        let count = 1024 * 1024
        let left = ArrayStorage([UInt8](repeating: 0, count: count))
        let right = ArrayStorage([UInt8](repeating: 1, count: count))

        var seen: [Double] = []
        let index = try await DiffEngine.scanAsync(
            left: left, right: right, chunkSize: 4096,
            progress: { seen.append($0) }
        )
        // Same blocks as the synchronous scan.
        XCTAssertEqual(index, try DiffEngine.scan(left: left, right: right, chunkSize: 4096))
        XCTAssertEqual(seen.last, 1.0, "final progress must be 1.0")
        XCTAssertTrue(seen.contains { $0 > 0 && $0 < 1 },
                      "expected intermediate progress, got \(seen)")
        XCTAssertEqual(seen, seen.sorted(), "progress must be monotonic")
    }

    /// The point of `scanAsync`'s per-chunk yield: a `progress` read issued from
    /// another task is serviced *during* a long build, not only after it. Before
    /// the yield was added, `build` was synchronous, so the actor starved every
    /// pending read until the scan returned — progress was unobservable.
    func testActorProgressIsObservableDuringBuild() async throws {
        let builder = DiffIndexBuilder()
        let chunkSize = 4 * 1024
        let chunks = 64
        // The left storage parks in `read` on the second chunk and says so, so
        // the sample below is issued while the build is provably in flight: one
        // chunk of progress is recorded and the build cannot advance a byte
        // until the test lets it.
        let left = GatedStorage(size: UInt64(chunkSize * chunks), byte: 0, parkAtRead: 2)
        let right = ArrayStorage([UInt8](repeating: 1, count: chunkSize * chunks))

        let buildTask = Task {
            try await builder.build(left: left, right: right, chunkSize: chunkSize)
        }
        await left.awaitPark()

        // Issued while the scan holds the build: it can only be answered before
        // the build ends if the scan does not own the actor for its whole run.
        // Verified by making `build` call the synchronous `scan` again — the
        // shape this test exists for — which makes this sample read 1.0.
        let sample = Task { await builder.progress }
        left.release()
        let midBuild = await sample.value

        XCTAssertGreaterThan(midBuild, 0, "a chunk had already been compared")
        XCTAssertLessThan(midBuild, 1, "the build was still in flight when the read was answered")

        _ = try await buildTask.value
        let final = await builder.progress
        XCTAssertEqual(final, 1.0, "a completed build reports 1.0")
    }

    // MARK: - Large files (§13.7)

    private func makeSparseFile(_ size: UInt64) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-diff-\(UUID().uuidString).bin")
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        XCTAssertEqual(Darwin.ftruncate(fd, off_t(size)), 0)
        return url
    }

    func testLargeSparseFilesProduceCorrectEOFOnlyBlocks() throws {
        // A 64 MiB all-zeros file vs a 32 MiB one: one giant same block, then an
        // EOF-only different block. Chunked scan must stream without loading it.
        let bigURL = try makeSparseFile(64 * 1024 * 1024)
        let smallURL = try makeSparseFile(32 * 1024 * 1024)
        let big = try FileBackedStorage(url: bigURL)
        let small = try FileBackedStorage(url: smallURL)

        let index = try DiffEngine.scan(left: big, right: small, chunkSize: 8 * 1024 * 1024)
        XCTAssertEqual(index.blocks, [
            Block(kind: .same, range: 0..<UInt64(32 * 1024 * 1024)),
            Block(kind: .different, range: UInt64(32 * 1024 * 1024)..<UInt64(64 * 1024 * 1024)),
        ])
    }

    func testLargeScanCancellationStopsEarly() throws {
        let bigURL = try makeSparseFile(64 * 1024 * 1024)
        let smallURL = try makeSparseFile(64 * 1024 * 1024)
        let big = try FileBackedStorage(url: bigURL)
        let small = try FileBackedStorage(url: smallURL)

        var chunks = 0
        XCTAssertThrowsError(try DiffEngine.scan(
            left: big, right: small, chunkSize: 8 * 1024 * 1024,
            shouldCancel: {
                chunks += 1
                return chunks > 2
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Builder cancel/reset lifecycle

    func testCancelThenResetAllowsNewBuild() async throws {
        let builder = DiffIndexBuilder()
        await builder.cancel()
        // A cancelled builder refuses to build…
        do {
            _ = try await builder.build(left: ArrayStorage([1]), right: ArrayStorage([2]))
            XCTFail("expected CancellationError after cancel()")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // …until reset() clears the flag, which also puts progress back to nothing.
        await builder.reset()
        let cleared = await builder.progress
        XCTAssertEqual(cleared, 0, "reset() clears the progress of the cancelled build")
        let index = try await builder.build(left: ArrayStorage([1]), right: ArrayStorage([2]))
        XCTAssertEqual(index.blocks.map(\.kind), [.different])
    }

    // MARK: - Net DiffEdit derivation (incremental undo/redo)

    /// One `DiffEdit` describing the damage a whole transaction did: the net
    /// length change, from the earliest offset the transaction moved bytes at.
    func testNetDiffEdit() {
        let cases: [(name: String, ops: [UndoOperation], expected: DiffEdit?)] = [
            ("a single overwrite",
             [.overwrite(range: 5..<6, before: [0x00], after: [0xFF])],
             .overwrite(range: 5..<6)),
            // Two nibbles of one byte = two overwrites of the same range.
            ("a typing pair coalesces to one overwrite",
             [.overwrite(range: 5..<6, before: [0x00], after: [0xA0]),
              .overwrite(range: 5..<6, before: [0x00], after: [0xA5])],
             .overwrite(range: 5..<6)),
            ("a single insert",
             [.insert(at: 2, bytes: [0xFF, 0xFE])],
             .insert(at: 2, length: 2)),
            ("a single delete",
             [.delete(range: 3..<6, bytes: [0x01, 0x02, 0x03])],
             .delete(range: 3..<6)),
            // replace(3..<8, [X, Y]) records an overwrite 3..<5 + delete 5..<8:
            // a net delete of three bytes from the earliest affected offset.
            ("a replace that shrinks becomes a delete",
             [.overwrite(range: 3..<5, before: [0x01, 0x02], after: [0xFF, 0xFE]),
              .delete(range: 5..<8, bytes: [0x03, 0x04, 0x05])],
             .delete(range: 3..<6)),
            // The split applyOverwrite produces for a paste past EOF: net +3, and
            // the earliest pre-shift offset is 5 — the overwritten byte stays at
            // 5, so the insert must start there.
            ("an overwrite past EOF becomes an insert",
             [.overwrite(range: 5..<6, before: [0x00], after: [0xFF]),
              .insert(at: 6, bytes: [0xAA, 0xBB, 0xCC])],
             .insert(at: 5, length: 3)),
            // Undo of a committed [delete(0..2), insert(at:4)] applies the
            // inverses reversed: an overwrite 4..<6 then an insert at 0. The
            // earliest pre-shift offset is 0, so the net edit is an insert there.
            ("an undo of delete-then-insert",
             [.overwrite(range: 4..<6, before: [0x01, 0x02], after: [0x01, 0x02]),
              .insert(at: 0, bytes: [0x00, 0x00])],
             .insert(at: 0, length: 2)),
            ("no ops at all",
             [],
             nil),
        ]
        for testCase in cases {
            XCTAssertEqual(DiffEdit.netDiffEdit(ops: testCase.ops), testCase.expected, testCase.name)
        }
    }

    // MARK: - Querying a window of the index (§8)

    /// The blocks touching a window, by binary search. Consumers that care about
    /// a few rows must not flatten the whole index to find them — that was a
    /// third of the main thread while typing into a 16 MB comparison.
    func testBlocksInAWindow() {
        // 0..10 same, 10..20 different, 20..30 same, 30..40 different.
        let index = DiffBlockIndex(leftSize: 40, rightSize: 40, blocks: [
            DiffBlock(kind: .same, range: 0..<10),
            DiffBlock(kind: .different, range: 10..<20),
            DiffBlock(kind: .same, range: 20..<30),
            DiffBlock(kind: .different, range: 30..<40),
        ])

        func kinds(_ range: Range<UInt64>) -> [String] {
            index.blocks(in: range).map { "\($0.kind == .same ? "s" : "d")\($0.range.lowerBound)" }
        }

        XCTAssertEqual(kinds(0..<40), ["s0", "d10", "s20", "d30"], "the whole extent")
        XCTAssertEqual(kinds(0..<1), ["s0"], "inside the first block")
        XCTAssertEqual(kinds(9..<11), ["s0", "d10"], "across a boundary")
        XCTAssertEqual(kinds(10..<20), ["d10"], "exactly one block")
        XCTAssertEqual(kinds(10..<21), ["d10", "s20"], "one block and a byte of the next")
        XCTAssertEqual(kinds(19..<20), ["d10"], "the last byte of a block")
        XCTAssertEqual(kinds(20..<20), [], "an empty window")
        XCTAssertEqual(kinds(40..<50), [], "past the extent")
        XCTAssertEqual(kinds(35..<50), ["d30"], "clamped at the end")
        XCTAssertEqual(DiffBlockIndex(leftSize: 0, rightSize: 0, blocks: []).blocks(in: 0..<10).count, 0)
    }

    /// The window query and the flattened list must agree — the same blocks, in
    /// the same order — over a random index.
    func testBlocksInAWindowAgreesWithTheWholeIndex() {
        let seed: UInt64 = 0x51D3_B10C_C5EE_D001
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<30 {
            var blocks: [DiffBlock] = []
            var offset: UInt64 = 0
            var kind = DiffBlock.Kind.same
            while offset < 500 {
                let length = UInt64.random(in: 1...40, using: &rng)
                blocks.append(DiffBlock(kind: kind, range: offset..<(offset + length)))
                offset += length
                kind = kind == .same ? .different : .same
            }
            let index = DiffBlockIndex(leftSize: offset, rightSize: offset, blocks: blocks)
            for _ in 0..<20 {
                let lower = UInt64.random(in: 0..<offset, using: &rng)
                // Non-empty windows only: an empty one holds nothing by
                // definition, and the naive filter below would disagree.
                let upper = min(offset, lower + UInt64.random(in: 1...120, using: &rng))
                let expected = index.blocks.filter {
                    $0.range.lowerBound < upper && $0.range.upperBound > lower
                }
                XCTAssertEqual(Array(index.blocks(in: lower..<upper)), expected,
                               "seed \(String(seed, radix: 16)) window \(lower)..<\(upper)")
            }
        }
    }

    // MARK: - Collapsing a batch (§8.3)

    /// Collapsing a batch of edits into the fewest that describe the same
    /// damage: one shift point (the earliest), overwrites merged where they
    /// touch, and overwrites the tail rescan already covers dropped.
    func testCollapse() {
        let typedInserts = (0..<10).map { DiffEdit.insert(at: 1000 + UInt64($0), length: 1) }
        let typedOverwrites = (0..<8).map {
            DiffEdit.overwrite(range: (100 + UInt64($0))..<(101 + UInt64($0)))
        }
        let cases: [(name: String, edits: [DiffEdit], expected: [DiffEdit])] = [
            ("nothing collapses to nothing", [], []),
            ("a lone overwrite is kept as it is",
             [.overwrite(range: 5..<9)], [.overwrite(range: 5..<9)]),
            ("a lone insert is kept as it is",
             [.insert(at: 5, length: 1)], [.insert(at: 5, length: 1)]),
            // A run of typed bytes in insert mode: every edit shifts from a
            // slightly higher offset, and the lowest one covers all of them.
            ("a run of inserts becomes the earliest one",
             typedInserts, [.insert(at: 1000, length: 1)]),
            ("the earliest shifting edit wins, whichever kind it is",
             [.insert(at: 900, length: 4), .delete(range: 40..<50), .insert(at: 500, length: 1)],
             [.delete(range: 40..<50)]),
            // Overwrites at or after the shift point are already covered by the
            // tail rescan; the part of one that reaches below it is not.
            ("an overwrite above the shift point is dropped",
             [.overwrite(range: 200..<300), .insert(at: 100, length: 1)],
             [.insert(at: 100, length: 1)]),
            ("an overwrite straddling the shift point is trimmed to it",
             [.overwrite(range: 50..<300), .insert(at: 100, length: 1)],
             [.overwrite(range: 50..<100), .insert(at: 100, length: 1)]),
            ("an overwrite entirely below the shift point survives whole",
             [.overwrite(range: 10..<20), .insert(at: 100, length: 1)],
             [.overwrite(range: 10..<20), .insert(at: 100, length: 1)]),
            // A run of typed bytes in overwrite mode: adjacent windows are one.
            ("a run of touching overwrites becomes one",
             typedOverwrites, [.overwrite(range: 100..<108)]),
            ("overlapping overwrites in any order become one",
             [.overwrite(range: 0..<10), .overwrite(range: 20..<30), .overwrite(range: 5..<22)],
             [.overwrite(range: 0..<30)]),
            ("overwrites with a gap between them stay apart",
             [.overwrite(range: 0..<10), .overwrite(range: 40..<50)],
             [.overwrite(range: 0..<10), .overwrite(range: 40..<50)]),
        ]
        for testCase in cases {
            XCTAssertEqual(DiffEdit.collapse(testCase.edits), testCase.expected, testCase.name)
        }
    }

    /// The collapsed batch must describe the same damage: applying it and
    /// applying the original edits one by one must land on the same index.
    func testCollapsedBatchGivesTheSameIndexAsApplyingEveryEdit() throws {
        let size = 4096
        let left = (0..<size).map { UInt8($0 % 251) }
        var right = left
        for i in 1000..<1100 { right[i] ^= 0xFF }
        let leftStorage = MemoryBackedStorage(bytes: left)
        let rightStorage = MemoryBackedStorage(bytes: right)
        // The left side ends up one byte longer, as an insert would leave it.
        let editedLeft = MemoryBackedStorage(bytes: [0xAA] + left)

        let base = try DiffEngine.scan(left: leftStorage, right: rightStorage)
        let batch: [DiffEdit] = [.overwrite(range: 10..<20), .insert(at: 0, length: 1),
                                 .overwrite(range: 3000..<3010)]

        var oneByOne = base
        for edit in batch {
            oneByOne = try DiffEngine.apply(edit, to: oneByOne, left: editedLeft, right: rightStorage)
        }
        var collapsed = base
        for edit in DiffEdit.collapse(batch) {
            collapsed = try DiffEngine.apply(edit, to: collapsed, left: editedLeft, right: rightStorage)
        }
        XCTAssertEqual(collapsed.blocks, oneByOne.blocks)
        XCTAssertEqual(collapsed.blocks, try DiffEngine.scan(left: editedLeft, right: rightStorage).blocks,
                       "and both agree with a full scan of the edited files")
    }

    // MARK: - The word-wise scan (§8.3)

    /// The chunked scan compares a machine word at a time, with `memcmp` for a
    /// chunk that matches whole. The runs it produces must be exactly the ones
    /// the byte-at-a-time reference produces — `blocks(left:right:)`, which is
    /// still written the obvious way. These are the shapes the word stepping
    /// could get wrong: runs shorter than a word, runs that straddle a word
    /// boundary, runs that end exactly on one, and a difference in the last
    /// bytes of the buffer.
    private func assertScanMatchesReference(_ left: [UInt8], _ right: [UInt8],
                                           chunkSize: Int = 64,
                                           _ message: String = "",
                                           line: UInt = #line) throws {
        let expected = DiffEngine.blocks(left: left, right: right)
        let scanned = try DiffEngine.scan(left: MemoryBackedStorage(bytes: left),
                                          right: MemoryBackedStorage(bytes: right),
                                          chunkSize: chunkSize).blocks
        XCTAssertEqual(scanned, expected, message, line: line)
    }

    func testWordWiseScanMatchesTheByteWiseReference() throws {
        let size = 200
        let base = (0..<size).map { UInt8($0 % 251) }

        // A single differing byte, at every offset in the first two words and
        // the last one — the boundaries word stepping can slip on.
        for offset in Array(0..<17) + [size - 9, size - 8, size - 1] {
            var other = base
            other[offset] ^= 0xFF
            try assertScanMatchesReference(base, other, "one byte differing at \(offset)")
        }

        // Differing runs of every length up to two words, at a few alignments.
        for start in [0, 1, 7, 8, 9, 62, 63, 64] {
            for length in 1...17 where start + length <= size {
                var other = base
                for i in start..<(start + length) { other[i] ^= 0xFF }
                try assertScanMatchesReference(base, other, "run \(start)..<\(start + length)")
            }
        }

        // Every byte differing, and none.
        try assertScanMatchesReference(base, base.map { $0 ^ 0xFF }, "all bytes differ")
        try assertScanMatchesReference(base, base, "no byte differs")

        // Unequal lengths: the tail of the longer file is one differing run.
        try assertScanMatchesReference(base, Array(base.prefix(100)), "shorter right")
        try assertScanMatchesReference(Array(base.prefix(100)), base, "shorter left")
        try assertScanMatchesReference([], base, "empty left")
        try assertScanMatchesReference(base, [], "empty right")
    }

    /// Runs that cross a chunk boundary must join, not break into two blocks:
    /// the `BlockBuilder` merges them, and the word stepping must not confuse it
    /// by ending a chunk mid-run.
    func testRunsCrossingChunkBoundariesMatchTheReference() throws {
        let size = 300
        let base = (0..<size).map { UInt8($0 % 251) }
        for chunk in [1, 2, 7, 8, 9, 16, 64, 100, 299, 300, 1024] {
            var other = base
            for i in 60..<70 { other[i] ^= 0xFF }         // spans a 64-byte boundary
            for i in 128..<136 { other[i] ^= 0xFF }       // starts on one
            try assertScanMatchesReference(base, other, chunkSize: chunk,
                                           "chunk size \(chunk)")
        }
    }

    /// A random walk over the same oracle: mostly-equal files with scattered
    /// differences, which is what the word stepping is tuned for, plus a few
    /// dense ones.
    func testRandomFilesMatchTheReference() throws {
        let seed: UInt64 = 0xD1FF_5EED_0000_2A2A
        var rng = SeededGenerator(seed: seed)
        for round in 0..<40 {
            let size = Int.random(in: 1...600, using: &rng)
            let left = (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var right = left
            let differences = Int.random(in: 0...(size / 2 + 1), using: &rng)
            for _ in 0..<differences {
                let at = Int.random(in: 0..<size, using: &rng)
                right[at] = UInt8.random(in: 0...255, using: &rng)
            }
            if Bool.random(using: &rng) { right.removeLast(Int.random(in: 0..<size, using: &rng)) }
            try assertScanMatchesReference(left, right,
                                           chunkSize: Int.random(in: 1...128, using: &rng),
                                           "seed \(String(seed, radix: 16)) round \(round)")
        }
    }
}
