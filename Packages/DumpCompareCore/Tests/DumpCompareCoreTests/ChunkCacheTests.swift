import XCTest
@testable import DumpCompareCore

final class ChunkCacheTests: XCTestCase {
    private func makeCache(chunkSize: Int, budget: Int) -> ChunkCache {
        ChunkCache(config: .init(chunkSize: chunkSize, byteBudget: budget))
    }

    private func chunk(_ value: UInt8, count: Int = 16) -> [UInt8] {
        Array(repeating: value, count: count)
    }

    /// The cache as a map: insert, look up, replace, remove. Every case runs
    /// under a budget far larger than it stores, so nothing is evicted and only
    /// the map behaviour shows — eviction has its own tests below.
    func testMapOperations() {
        let cases: [(name: String, act: (ChunkCache) -> Void,
                     present: [(index: UInt64, value: UInt8)], absent: [UInt64],
                     count: Int, cachedBytes: Int?)] = [
            ("insert and retrieve",
             {
                 $0.setChunk(0, bytes: self.chunk(0xAA))
                 $0.setChunk(1, bytes: self.chunk(0xBB))
             },
             [(0, 0xAA), (1, 0xBB)], [], 2, 32),
            ("a chunk that was never inserted is missing",
             { _ in },
             [], [99], 0, 0),
            ("replacing a chunk keeps one entry",
             {
                 $0.setChunk(3, bytes: self.chunk(0x01))
                 $0.setChunk(3, bytes: self.chunk(0x02))
             },
             [(3, 0x02)], [], 1, 16),
            ("remove drops just that entry",
             {
                 $0.setChunk(7, bytes: self.chunk(0))
                 $0.setChunk(8, bytes: self.chunk(0))
                 $0.remove(7)
             },
             [(8, 0)], [7], 1, 16),
            ("removeAll empties the cache",
             {
                 for i in 0..<5 { $0.setChunk(UInt64(i), bytes: self.chunk(0)) }
                 $0.removeAll()
             },
             [], [0, 4], 0, 0),
        ]
        for testCase in cases {
            let cache = makeCache(chunkSize: 16, budget: 1024)
            testCase.act(cache)
            for hit in testCase.present {
                XCTAssertEqual(cache.chunk(hit.index), chunk(hit.value),
                               "\(testCase.name): chunk \(hit.index)")
            }
            for index in testCase.absent {
                XCTAssertNil(cache.chunk(index), "\(testCase.name): chunk \(index)")
            }
            XCTAssertEqual(cache.count, testCase.count, "\(testCase.name): count")
            if let cachedBytes = testCase.cachedBytes {
                XCTAssertEqual(cache.cachedByteCount, cachedBytes,
                               "\(testCase.name): cachedByteCount")
            }
        }
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

    func testCachedByteCountTracksBudget() {
        let cache = makeCache(chunkSize: 16, budget: 48)
        for i in 0..<5 { cache.setChunk(UInt64(i), bytes: chunk(0)) }
        // 5 × 16 = 80 written, evicted down to ≤ 48 → exactly 3 chunks remain.
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.cachedByteCount, 48)
    }
}
