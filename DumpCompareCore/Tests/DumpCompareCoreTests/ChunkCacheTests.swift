import XCTest
@testable import DumpCompareCore

final class ChunkCacheTests: XCTestCase {
    private func makeCache(chunkSize: Int, budget: Int) -> ChunkCache {
        ChunkCache(config: .init(chunkSize: chunkSize, byteBudget: budget))
    }

    private func chunk(_ value: UInt8, count: Int = 16) -> [UInt8] {
        Array(repeating: value, count: count)
    }

    func testInsertAndRetrieve() {
        let cache = makeCache(chunkSize: 16, budget: 1024)
        cache.setChunk(0, bytes: chunk(0xAA))
        cache.setChunk(1, bytes: chunk(0xBB))
        XCTAssertEqual(cache.chunk(0), chunk(0xAA))
        XCTAssertEqual(cache.chunk(1), chunk(0xBB))
        XCTAssertEqual(cache.count, 2)
    }

    func testMissingChunkReturnsNil() {
        let cache = makeCache(chunkSize: 16, budget: 1024)
        XCTAssertNil(cache.chunk(99))
    }

    func testEvictsLeastRecentlyUsed() {
        let cache = makeCache(chunkSize: 16, budget: 64) // holds exactly 4 chunks
        for i in 0..<4 { cache.setChunk(UInt64(i), bytes: chunk(0)) }

        cache.setChunk(4, bytes: chunk(0)) // evicts the LRU: chunk 0
        XCTAssertNil(cache.chunk(0))
        XCTAssertNotNil(cache.chunk(1))
        XCTAssertNotNil(cache.chunk(4))
    }

    func testAccessUpdatesRecency() {
        let cache = makeCache(chunkSize: 16, budget: 64)
        for i in 0..<4 { cache.setChunk(UInt64(i), bytes: chunk(0)) }

        _ = cache.chunk(0) // touch 0, making 1 the LRU
        cache.setChunk(4, bytes: chunk(0))
        XCTAssertNotNil(cache.chunk(0))
        XCTAssertNil(cache.chunk(1))
    }

    func testReplaceUpdatesSize() {
        let cache = makeCache(chunkSize: 16, budget: 1024)
        cache.setChunk(3, bytes: chunk(0x01))
        cache.setChunk(3, bytes: chunk(0x02))
        XCTAssertEqual(cache.chunk(3), chunk(0x02))
        XCTAssertEqual(cache.count, 1)
    }

    func testRemove() {
        let cache = makeCache(chunkSize: 16, budget: 1024)
        cache.setChunk(7, bytes: chunk(0))
        cache.remove(7)
        XCTAssertNil(cache.chunk(7))
        XCTAssertEqual(cache.count, 0)
    }

    func testRemoveAll() {
        let cache = makeCache(chunkSize: 16, budget: 1024)
        for i in 0..<5 { cache.setChunk(UInt64(i), bytes: chunk(0)) }
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.cachedByteCount, 0)
    }

    func testCachedByteCountTracksBudget() {
        let cache = makeCache(chunkSize: 16, budget: 48)
        for i in 0..<5 { cache.setChunk(UInt64(i), bytes: chunk(0)) }
        // 5 × 16 = 80 written, evicted down to ≤ 48 → exactly 3 chunks remain.
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.cachedByteCount, 48)
    }
}
