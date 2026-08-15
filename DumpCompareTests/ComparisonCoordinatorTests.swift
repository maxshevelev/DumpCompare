import DumpCompareCore
import XCTest
@testable import DumpCompare

/// M5 integration tests for the comparison coordinator: background index build,
/// incremental edit application (overwrite/insert/delete), and navigation
/// against the built index (§8.3, §10.3).
@MainActor
final class ComparisonCoordinatorTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Two panes wired to a coordinator over the same two temp files. The files
    /// stay open on disk for the whole test (the storage reads them lazily).
    private func makeCoordinator(
        _ left: [UInt8], _ right: [UInt8]
    ) throws -> (coordinator: ComparisonCoordinator, paneA: PaneViewModel, paneB: PaneViewModel, urlA: URL, urlB: URL) {
        let urlA = try tempFile(left)
        let urlB = try tempFile(right)
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        let coordinator = ComparisonCoordinator {
            guard let a = paneA.byteStorage, let b = paneB.byteStorage else { return nil }
            return (a, b)
        }
        paneA.onEdit = { coordinator.record(edit: $0) }
        paneB.onEdit = { coordinator.record(edit: $0) }
        return (coordinator, paneA, paneB, urlA, urlB)
    }

    private func awaitBuild(_ coordinator: ComparisonCoordinator) async -> Bool {
        await waitUntil { !coordinator.isBuilding && coordinator.index != nil }
    }

    // MARK: - Build + navigation

    func testBuildsIndexAndNavigates() async throws {
        let (coordinator, _, _, urlA, urlB) = try makeCoordinator(
            [0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03],
            [0x00, 0x00, 0x09, 0x09, 0x02, 0x02, 0x08, 0x08]
        )
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        coordinator.start()
        let built = await awaitBuild(coordinator)
        XCTAssertTrue(built, "index never built")

        guard let index = coordinator.index else { return XCTFail("no index") }
        XCTAssertEqual(index.blocks.map(\.kind), [.same, .different, .same, .different])
        XCTAssertEqual(index.blocks[1].range, 2..<4)

        // Navigation against the built index.
        let nextDiff = coordinator.findBlock(kind: .different, direction: .forward, from: 0)
        XCTAssertEqual(nextDiff?.range, 2..<4)
        // `same` block at 0..<2 starts exactly at the search offset → not strictly after.
        let nextSame = coordinator.findBlock(kind: .same, direction: .forward, from: 0)
        XCTAssertEqual(nextSame?.range, 4..<6)
        let prevDiff = coordinator.findBlock(kind: .different, direction: .backward, from: index.maxSize)
        XCTAssertEqual(prevDiff?.range, 6..<8)
        let noneAfterEOF = coordinator.findBlock(kind: .different, direction: .forward, from: index.maxSize)
        XCTAssertNil(noneAfterEOF)
    }

    /// While the index is building, navigation must not fire: `findBlock` has
    /// no live-scan fallback and returns nil, so the UI reports "not found"
    /// (beep + message) instead of racing the build (§10.3).
    func testFindBlockReturnsNilWhileIndexBuilding() throws {
        let (coordinator, _, _, urlA, urlB) = try makeCoordinator(
            [0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03],
            [0x00, 0x00, 0x09, 0x09, 0x02, 0x02, 0x08, 0x08]
        )
        defer {
            coordinator.stop()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        coordinator.start()
        // Right after start() the index is nil and the build is in flight;
        // nothing between the two calls lets the build land.
        XCTAssertTrue(coordinator.isBuilding)
        let result = coordinator.findBlock(kind: .different, direction: .forward, from: 0)
        XCTAssertNil(result, "findBlock must not fire while the index is building")
    }

    // MARK: - Incremental edit application (§8.3)

    func testOverwriteEditRecomputesOnlyAffectedRange() async throws {
        let (coordinator, paneA, _, urlA, urlB) = try makeCoordinator(
            [0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03],
            [0x00, 0x00, 0x09, 0x09, 0x02, 0x02, 0x08, 0x08]
        )
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        var changeCount = 0
        coordinator.onIndexChanged = { _ in changeCount += 1 }

        coordinator.start()
        let built = await awaitBuild(coordinator)
        XCTAssertTrue(built)
        changeCount = 0  // the initial build already fired onIndexChanged once

        // Overwrite byte 0 → 0xFF. Byte 1 stays same, so the diff run shrinks.
        paneA.moveCaret(to: 0)
        paneA.typeHexNibble(0xF)
        paneA.typeHexNibble(0xF)
        let applied = await waitUntil { changeCount >= 1 }
        XCTAssertTrue(applied, "edit never applied")

        guard let index = coordinator.index else { return XCTFail("index lost after edit") }
        // left now [FF,0,1,1,2,2,3,3] vs right [0,0,9,9,2,2,8,8]
        XCTAssertEqual(index.blocks.map(\.kind), [.different, .same, .different, .same, .different])
        XCTAssertEqual(index.blocks[0].range, 0..<1)
        XCTAssertEqual(index.blocks[2].range, 2..<4)
        XCTAssertEqual(index.maxSize, 8)
    }

    func testInsertEditShiftsOffsets() async throws {
        let (coordinator, paneA, _, urlA, urlB) = try makeCoordinator(
            [0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03],
            [0x00, 0x00, 0x09, 0x09, 0x02, 0x02, 0x08, 0x08]
        )
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        var changeCount = 0
        coordinator.onIndexChanged = { _ in changeCount += 1 }

        coordinator.start()
        let built = await awaitBuild(coordinator)
        XCTAssertTrue(built)
        changeCount = 0  // the initial build already fired onIndexChanged once

        paneA.moveCaret(to: 0)
        try paneA.pasteInsert([0xFF])
        let applied = await waitUntil { changeCount >= 1 }
        XCTAssertTrue(applied, "insert never applied")

        guard let index = coordinator.index else { return XCTFail("index lost after insert") }
        // left = [FF,0,0,1,1,2,2,3,3] (9), right unchanged (8)
        XCTAssertEqual(index.maxSize, 9)
        XCTAssertEqual(index.leftSize, 9)
        XCTAssertEqual(index.rightSize, 8)
        // diff[0,1) same[1,2) diff[2,4) same[4,6) diff[6,9); the tail folds EOF-only byte 8 in.
        XCTAssertEqual(index.blocks.map(\.kind), [.different, .same, .different, .same, .different])
        XCTAssertEqual(index.blocks.last?.range, 6..<9)
    }

    func testDeleteEditReindexes() async throws {
        let (coordinator, _, paneB, urlA, urlB) = try makeCoordinator(
            [0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03],
            [0x00, 0x00, 0x09, 0x09, 0x02, 0x02, 0x08, 0x08]
        )
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        var changeCount = 0
        coordinator.onIndexChanged = { _ in changeCount += 1 }

        coordinator.start()
        let built = await awaitBuild(coordinator)
        XCTAssertTrue(built)
        changeCount = 0  // the initial build already fired onIndexChanged once

        // Remove the two differing bytes in the right pane.
        paneB.moveCaret(to: 2)
        try paneB.deleteBytes(in: 2..<4)
        let applied = await waitUntil { changeCount >= 1 }
        XCTAssertTrue(applied, "delete never applied")

        guard let index = coordinator.index else { return XCTFail("index lost after delete") }
        // right = [0,0,2,2,8,8]; EOF-only left bytes [3,3] fold into the tail diff.
        XCTAssertEqual(index.maxSize, 8)
        XCTAssertEqual(index.blocks.map(\.kind), [.same, .different])
        XCTAssertEqual(index.blocks[0].range, 0..<2)
        XCTAssertEqual(index.blocks[1].range, 2..<8)
    }

    // MARK: - Lifecycle

    func testStopDropsIndex() async throws {
        let (coordinator, _, _, urlA, urlB) = try makeCoordinator([0x00], [0x00])
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        coordinator.start()
        let built = await awaitBuild(coordinator)
        XCTAssertTrue(built)
        XCTAssertNotNil(coordinator.index)

        coordinator.stop()
        XCTAssertNil(coordinator.index)
        XCTAssertFalse(coordinator.isBuilding)
        // Edits after stop are ignored (guard on `isBuilding || index != nil`).
        coordinator.record(edit: .overwrite(range: 0..<1))
        XCTAssertNil(coordinator.index)
    }

    // MARK: - Background operation (§14.4)

    /// `cancelBuild()` (the operation's × button) stops the build without
    /// restarting: the index stays nil, the operation finishes, and a fresh
    /// `start()` builds normally afterwards.
    func testCancelBuildStopsIndexingAndDropsResult() async throws {
        let (coordinator, _, _, urlA, urlB) = try makeCoordinator([0x00], [0x00])
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        var presented: BackgroundOperation?
        coordinator.onOperation = { presented = $0 }
        coordinator.start()
        XCTAssertTrue(coordinator.isBuilding)
        let op = try XCTUnwrap(coordinator.operation, "start() must surface a build operation")
        XCTAssertTrue(presented === op, "the surfaced operation must be the coordinator's")

        // Cancel before the build's first background task even starts: the
        // generation guard drops the stale result, so no index is published.
        coordinator.cancelBuild()
        XCTAssertFalse(coordinator.isBuilding)
        XCTAssertNil(coordinator.operation, "cancel must clear the operation")

        let settled = await waitUntil { !op.isActive }
        XCTAssertTrue(settled, "the operation must finish on cancel")
        XCTAssertNil(coordinator.index, "a cancelled build must not publish an index")

        // A fresh start() builds normally.
        coordinator.start()
        let rebuilt = await awaitBuild(coordinator)
        XCTAssertTrue(rebuilt, "a fresh start must build after a cancel")
        XCTAssertNotNil(coordinator.index)
    }
}
