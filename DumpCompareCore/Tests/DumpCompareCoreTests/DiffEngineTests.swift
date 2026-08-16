import XCTest
@testable import DumpCompareCore

final class DiffEngineTests: XCTestCase {
    private typealias Block = DiffBlock
    private typealias Kind = DiffBlock.Kind

    private func blocks(_ left: [UInt8], _ right: [UInt8]) -> [DiffBlock] {
        DiffEngine.blocks(left: left, right: right)
    }

    private func index(_ left: [UInt8], _ right: [UInt8], chunkSize: Int = DiffEngine.defaultChunkSize) throws -> DiffBlockIndex {
        try DiffEngine.scan(left: ArrayStorage(left), right: ArrayStorage(right), chunkSize: chunkSize)
    }

    // MARK: - Block construction

    func testIdenticalFiles() {
        XCTAssertEqual(blocks([0x01, 0x02, 0x03], [0x01, 0x02, 0x03]),
                       [Block(kind: .same, range: 0..<3)])
    }

    func testCompletelyDifferent() {
        XCTAssertEqual(blocks([0x01, 0x02, 0x03], [0xFF, 0xFE, 0xFD]),
                       [Block(kind: .different, range: 0..<3)])
    }

    func testSingleByteDifference() {
        XCTAssertEqual(blocks([0xAA, 0x00, 0xAA], [0xAA, 0x01, 0xAA]), [
            Block(kind: .same, range: 0..<1),
            Block(kind: .different, range: 1..<2),
            Block(kind: .same, range: 2..<3),
        ])
    }

    func testMultipleDifferenceBlocks() {
        XCTAssertEqual(blocks([0x00, 0x00, 0x00, 0x00], [0x01, 0x00, 0x01, 0x00]), [
            Block(kind: .different, range: 0..<1),
            Block(kind: .same, range: 1..<2),
            Block(kind: .different, range: 2..<3),
            Block(kind: .same, range: 3..<4),
        ])
    }

    func testEmptyFile() {
        XCTAssertEqual(blocks([], [1, 2, 3]), [Block(kind: .different, range: 0..<3)])
        XCTAssertEqual(blocks([1, 2, 3], []), [Block(kind: .different, range: 0..<3)])
        XCTAssertEqual(blocks([], []), [])
    }

    func testEOFOnlyTailFoldedIntoDifferent() {
        XCTAssertEqual(blocks([0x00, 0x01], [0x00, 0x01, 0xAA]), [
            Block(kind: .same, range: 0..<2),
            Block(kind: .different, range: 2..<3),
        ])
        XCTAssertEqual(blocks([0x00, 0x01, 0xAA], [0x00, 0x01]), [
            Block(kind: .same, range: 0..<2),
            Block(kind: .different, range: 2..<3),
        ])
    }

    func testEOFOnlyMergesWithAdjacentDifference() {
        // Byte 1 differs and the tail is EOF-only → one different block [1, 4).
        XCTAssertEqual(blocks([0x00, 0x00, 0x01, 0x02], [0x00, 0xFF]), [
            Block(kind: .same, range: 0..<1),
            Block(kind: .different, range: 1..<4),
        ])
    }

    // MARK: - Chunked scan

    func testScanMatchesArrayVersionAcrossChunks() throws {
        let left = [UInt8]([0, 1, 2, 3, 4, 5, 6, 7])
        let right = [UInt8]([0, 1, 9, 3, 4, 5, 6, 8])
        for chunk in [1, 2, 3, 5, 100] {
            let scanned = try index(left, right, chunkSize: chunk)
            XCTAssertEqual(scanned.blocks, blocks(left, right), "chunk size \(chunk)")
        }
    }

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

    // MARK: - Incremental invalidation

    func testApplyOverwriteTurnsSameIntoDifferent() throws {
        let right = ArrayStorage([0x01, 0x02, 0x03, 0x04])
        let base = try DiffEngine.scan(left: right, right: right)   // all same

        let edited = ArrayStorage([0x01, 0xFF, 0x03, 0x04])
        let updated = try DiffEngine.apply(.overwrite(range: 1..<2), to: base, left: edited, right: right, chunkSize: 2)
        let expected = try DiffEngine.scan(left: edited, right: right, chunkSize: 2)
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(updated.blocks, [
            Block(kind: .same, range: 0..<1),
            Block(kind: .different, range: 1..<2),
            Block(kind: .same, range: 2..<4),
        ])
    }

    func testApplyOverwriteTurnsDifferentIntoSame() throws {
        let right = ArrayStorage([0x01, 0x02, 0x03, 0x04])
        let edited = ArrayStorage([0x01, 0xFF, 0x03, 0x04])
        let base = try DiffEngine.scan(left: edited, right: right)

        let reverted = ArrayStorage([0x01, 0x02, 0x03, 0x04])
        let updated = try DiffEngine.apply(.overwrite(range: 1..<2), to: base, left: reverted, right: right)
        XCTAssertEqual(updated.blocks, [Block(kind: .same, range: 0..<4)])
    }

    func testApplyOverwriteExtendingEOF() throws {
        let left = ArrayStorage([0x01, 0x02])
        let right = ArrayStorage([0x01, 0x02])
        let base = try DiffEngine.scan(left: left, right: right)

        let extended = ArrayStorage([0x01, 0x03, 0x04])
        let updated = try DiffEngine.apply(.overwrite(range: 1..<3), to: base, left: extended, right: right)
        let expected = try DiffEngine.scan(left: extended, right: right)
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(updated.blocks, [
            Block(kind: .same, range: 0..<1),
            Block(kind: .different, range: 1..<3),
        ])
    }

    func testApplyOverwriteEntirelyPastEOF() throws {
        let base = try DiffEngine.scan(left: ArrayStorage([]), right: ArrayStorage([]))
        let edited = ArrayStorage([0xAA, 0xBB, 0xCC])
        let updated = try DiffEngine.apply(.overwrite(range: 2..<5), to: base, left: edited, right: ArrayStorage([]))
        XCTAssertEqual(updated.blocks, [Block(kind: .different, range: 0..<3)])
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

    func testActorCancelThrows() async {
        let builder = DiffIndexBuilder()
        await builder.cancel()
        do {
            _ = try await builder.build(
                left: ArrayStorage([UInt8](repeating: 0, count: 8)),
                right: ArrayStorage([UInt8](repeating: 1, count: 8)),
                chunkSize: 2
            )
            XCTFail("expected cancellation error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
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
        // 8 MiB in 4 KiB chunks → 2048 chunk boundaries to yield at, so the
        // build spans many sampling reads rather than finishing in one slice.
        let count = 8 * 1024 * 1024
        let left = ArrayStorage([UInt8](repeating: 0, count: count))
        let right = ArrayStorage([UInt8](repeating: 1, count: count))

        let buildTask = Task {
            try await builder.build(left: left, right: right, chunkSize: 4 * 1024)
        }

        var samples: [Double] = []
        for _ in 0..<100_000 {
            let p = await builder.progress
            samples.append(p)
            if p >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000)
        }
        _ = try await buildTask.value

        XCTAssertEqual(samples.last, 1.0, "a completed build must report 1.0")
        XCTAssertTrue(samples.contains { $0 > 0 && $0 < 1 },
                      "expected an intermediate progress sample mid-build, got \(samples)")
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

    // MARK: - On-demand block search (findBlock)

    /// Blocks: same[0,2) diff[2,4) same[4,6) diff[6,8)
    private func makeAlternating() -> (ArrayStorage, ArrayStorage) {
        (ArrayStorage([0, 0, 1, 1, 2, 2, 3, 3]),
         ArrayStorage([0, 0, 9, 9, 2, 2, 8, 8]))
    }

    func testFindBlockForward() throws {
        let (left, right) = makeAlternating()
        // Matches index.nextDifference semantics: strictly after.
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .forward, from: 0, left: left, right: right)?.range, 2..<4)
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .forward, from: 2, left: left, right: right)?.range, 6..<8)
        XCTAssertNil(try DiffEngine.findBlock(kind: .different, direction: .forward, from: 7, left: left, right: right))
        XCTAssertEqual(try DiffEngine.findBlock(kind: .same, direction: .forward, from: 1, left: left, right: right)?.range, 4..<6)
        XCTAssertNil(try DiffEngine.findBlock(kind: .same, direction: .forward, from: 4, left: left, right: right))
    }

    func testFindBlockBackward() throws {
        let (left, right) = makeAlternating()
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .backward, from: 4, left: left, right: right)?.range, 2..<4)
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .backward, from: 8, left: left, right: right)?.range, 6..<8)
        XCTAssertNil(try DiffEngine.findBlock(kind: .different, direction: .backward, from: 1, left: left, right: right))
        XCTAssertEqual(try DiffEngine.findBlock(kind: .same, direction: .backward, from: 7, left: left, right: right)?.range, 4..<6)
    }

    func testFindBlockMatchesIndexNavigation() throws {
        let (left, right) = makeAlternating()
        let index = try DiffEngine.scan(left: left, right: right)
        let offsets: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7]
        for offset in offsets {
            for kind in [Kind.same, Kind.different] {
                for direction in [SearchDirection.forward, SearchDirection.backward] {
                    let viaIndex: DiffBlock? = {
                        switch (kind, direction) {
                        case (.different, .forward): return index.nextDifference(from: offset)
                        case (.different, .backward): return index.previousDifference(from: offset)
                        case (.same, .forward): return index.nextSame(from: offset)
                        case (.same, .backward): return index.previousSame(from: offset)
                        }
                    }()
                    let viaScan = try DiffEngine.findBlock(
                        kind: kind, direction: direction, from: offset, left: left, right: right
                    )
                    XCTAssertEqual(viaScan?.range, viaIndex?.range,
                                   "kind=\(kind) direction=\(direction) from=\(offset)")
                }
            }
        }
    }

    func testFindBlockIncludesEOFOnlyTail() throws {
        let left = ArrayStorage([0x00, 0x01])
        let right = ArrayStorage([0x00, 0x01, 0xAA, 0xBB])
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .forward, from: 0, left: left, right: right)?.range, 2..<4)
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .backward, from: 4, left: left, right: right)?.range, 2..<4)
        // An all-equal shorter pair still has the EOF-only tail as a diff block.
        let eq = ArrayStorage([0x01, 0x02])
        let longer = ArrayStorage([0x01, 0x02, 0x03])
        XCTAssertEqual(try DiffEngine.findBlock(kind: .different, direction: .forward, from: 0, left: eq, right: longer)?.range, 2..<3)
    }

    func testFindBlockOnDemandScanAtActor() async throws {
        let builder = DiffIndexBuilder()
        let result = try await builder.scanForBlock(
            kind: .different, direction: .forward, from: 0,
            left: ArrayStorage([0, 1, 2]), right: ArrayStorage([0, 9, 9])
        )
        XCTAssertEqual(result?.range, 1..<3)
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
        // …until reset() clears the flag.
        await builder.reset()
        let index = try await builder.build(left: ArrayStorage([1]), right: ArrayStorage([2]))
        XCTAssertEqual(index.blocks.map(\.kind), [.different])
    }

    func testResetClearsProgress() async throws {
        let builder = DiffIndexBuilder()
        await builder.cancel()
        await builder.reset()
        let p = await builder.progress
        XCTAssertEqual(p, 0)
    }

    // MARK: - Net DiffEdit derivation (incremental undo/redo)

    func testNetDiffEditSingleOverwrite() {
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .overwrite(range: 5..<6, before: [0x00], after: [0xFF]),
        ]), .overwrite(range: 5..<6))
    }

    func testNetDiffEditTypingPairCoalescesToOverwrite() {
        // Two nibbles of one byte = two overwrites of the same range.
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .overwrite(range: 5..<6, before: [0x00], after: [0xA0]),
            .overwrite(range: 5..<6, before: [0x00], after: [0xA5]),
        ]), .overwrite(range: 5..<6))
    }

    func testNetDiffEditSingleInsert() {
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .insert(at: 2, bytes: [0xFF, 0xFE]),
        ]), .insert(at: 2, length: 2))
    }

    func testNetDiffEditSingleDelete() {
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .delete(range: 3..<6, bytes: [0x01, 0x02, 0x03]),
        ]), .delete(range: 3..<6))
    }

    func testNetDiffEditReplaceShrinksToDelete() {
        // replace(3..<8, [X, Y]) records an overwrite 3..<5 + delete 5..<8:
        // a net delete of three bytes from the earliest affected offset.
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .overwrite(range: 3..<5, before: [0x01, 0x02], after: [0xFF, 0xFE]),
            .delete(range: 5..<8, bytes: [0x03, 0x04, 0x05]),
        ]), .delete(range: 3..<6))
    }

    func testNetDiffEditOverwritePastEOFBecomesInsert() {
        // overwrite 5..<6 + insert at 6 of 3 (the split applyOverwrite produces
        // for a paste past EOF): net +3, and the earliest pre-shift offset is 5 —
        // the overwritten byte stays at 5, so the insert must start there.
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .overwrite(range: 5..<6, before: [0x00], after: [0xFF]),
            .insert(at: 6, bytes: [0xAA, 0xBB, 0xCC]),
        ]), .insert(at: 5, length: 3))
    }

    func testNetDiffEditUndoOfDeleteThenInsert() {
        // Undo of a committed [delete(0..2), insert(at:4)] applies the inverses
        // reversed: an overwrite 4..<6 then an insert at 0. The earliest
        // pre-shift offset is 0, so the net edit is an insert there.
        XCTAssertEqual(DiffEdit.netDiffEdit(ops: [
            .overwrite(range: 4..<6, before: [0x01, 0x02], after: [0x01, 0x02]),
            .insert(at: 0, bytes: [0x00, 0x00]),
        ]), .insert(at: 0, length: 2))
    }

    func testNetDiffEditEmptyReturnsNil() {
        XCTAssertNil(DiffEdit.netDiffEdit(ops: []))
    }
}
