import XCTest
@testable import DumpCompareCore

/// What the piece table exists for: an edit must not cost a copy of the file.
/// These tests pin the properties, not the timings — a measurement is in
/// `Design/PIECE_TABLE_PLAN.md` — but the properties are what make the timings
/// possible, and they are the ones a future change could quietly lose.
final class EditOverlayStorageCostTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    private func makeFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        urls.append(url)
        return url
    }

    private func makeStorage(_ bytes: [UInt8],
                             budgets: EditOverlayStorage.Budgets = .init(),
                             store: TemporaryFileStore = TemporaryFileStore())
    throws -> EditOverlayStorage {
        let url = try makeFile(bytes)
        return EditOverlayStorage(base: try FileBackedStorage(url: url),
                                  tempStore: store, budgets: budgets)
    }

    /// Files a temporary store has on disk right now.
    private func tempFileCount(_ directory: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil)) ?? []).count
    }

    private func storeDirectory(_ store: TemporaryFileStore) throws -> URL {
        let probe = try store.createTempURL()
        try? FileManager.default.removeItem(at: probe)
        return probe.deletingLastPathComponent()
    }

    /// A typed run: a hundred single-byte inserts leave no file copies behind and
    /// no pile of pieces. Before the piece table this wrote a hundred full copies
    /// of the file into the temp directory.
    func testATypedRunCopiesNothingAndStaysCompact() throws {
        let store = TemporaryFileStore()
        let directory = try storeDirectory(store)
        let storage = try makeStorage([UInt8](repeating: 0xFF, count: 200_000), store: store)

        for i in 0..<100 {
            try storage.insert(at: 1000 + UInt64(i), bytes: [UInt8(i)])
        }

        XCTAssertEqual(storage.size, 200_100)
        XCTAssertEqual(tempFileCount(directory), 0, "no edit materialized a copy of the file")
        XCTAssertEqual(storage.pieceCount, 3, "the run coalesced into one piece")

        // And the content is what was typed.
        XCTAssertEqual(try storage.read(at: 998, length: 6), [0xFF, 0xFF, 0, 1, 2, 3])
        XCTAssertEqual(try storage.read(at: 1100, length: 2), [0xFF, 0xFF])
    }

    /// Deleting is as cheap: no copy, and the bytes after the hole move up.
    func testDeleteCopiesNothing() throws {
        let store = TemporaryFileStore()
        let directory = try storeDirectory(store)
        let storage = try makeStorage(Array(0..<100), store: store)

        for _ in 0..<20 { try storage.delete(range: 10..<11) }

        XCTAssertEqual(storage.size, 80)
        XCTAssertEqual(try storage.read(at: 8, length: 4), [8, 9, 30, 31])
        XCTAssertEqual(tempFileCount(directory), 0)
    }

    /// The valve: an insert bigger than the inline budget is folded into a new
    /// base, and only one such file is ever kept — not one per edit.
    func testAnOversizedInsertMaterializesOnceAndKeepsOneCopy() throws {
        let store = TemporaryFileStore()
        let directory = try storeDirectory(store)
        let budgets = EditOverlayStorage.Budgets(maxInlineInsert: 1024,
                                                maxAddedBytes: 1 << 20,
                                                maxPieces: 100_000)
        let storage = try makeStorage([UInt8](repeating: 0x11, count: 4096),
                                      budgets: budgets, store: store)

        try storage.insert(at: 100, bytes: [UInt8](repeating: 0x22, count: 2048))
        XCTAssertEqual(storage.pieceCount, 1, "the table collapsed into one base piece")
        XCTAssertEqual(tempFileCount(directory), 1)

        try storage.insert(at: 200, bytes: [UInt8](repeating: 0x33, count: 2048))
        XCTAssertEqual(tempFileCount(directory), 1, "the previous copy is not kept")

        XCTAssertEqual(storage.size, 4096 + 4096)
        XCTAssertEqual(try storage.read(at: 199, length: 3), [0x22, 0x33, 0x33])
    }

    /// The add buffer does not grow without bound: once it passes its budget the
    /// bytes are folded into the base and the buffer starts over.
    func testTheAddBufferIsFoldedIntoTheBaseWhenItGrowsTooLarge() throws {
        let store = TemporaryFileStore()
        let directory = try storeDirectory(store)
        let budgets = EditOverlayStorage.Budgets(maxInlineInsert: 1 << 20,
                                                maxAddedBytes: 4096,
                                                maxPieces: 100_000)
        let storage = try makeStorage([UInt8](repeating: 0xFF, count: 1000),
                                      budgets: budgets, store: store)

        for i in 0..<6000 { try storage.insert(at: UInt64(i), bytes: [0xAB]) }

        XCTAssertEqual(storage.size, 7000)
        XCTAssertGreaterThanOrEqual(tempFileCount(directory), 1, "the buffer was folded in")
        XCTAssertLessThanOrEqual(tempFileCount(directory), 1, "and only the latest fold is kept")
        XCTAssertEqual(try storage.read(at: 0, length: 4), [0xAB, 0xAB, 0xAB, 0xAB])
        XCTAssertEqual(try storage.read(at: 6999, length: 1), [0xFF])
    }

    /// The piece budget is the other valve: a scattered edit pattern collapses
    /// once the list gets long, so reads never walk thousands of pieces.
    func testAScatteredEditPatternCollapsesOnThePieceBudget() throws {
        let budgets = EditOverlayStorage.Budgets(maxInlineInsert: 1 << 20,
                                                maxAddedBytes: 1 << 20,
                                                maxPieces: 50)
        let storage = try makeStorage([UInt8](repeating: 0xFF, count: 10_000), budgets: budgets)

        // Insert at descending offsets, so no two inserts continue one another.
        for i in stride(from: 9000, to: 0, by: -100) {
            try storage.insert(at: UInt64(i), bytes: [0xEE])
        }

        XCTAssertLessThanOrEqual(storage.pieceCount, 51)
        XCTAssertEqual(storage.size, 10_090)
    }

    /// Overwrites still record what an in-place save has to patch, including the
    /// ones a materialization folded into the base — otherwise saving after a
    /// long overwrite-only session would write nothing.
    func testChangedRangesSurviveAMaterialization() throws {
        let budgets = EditOverlayStorage.Budgets(maxInlineInsert: 1 << 20,
                                                maxAddedBytes: 8,
                                                maxPieces: 100_000)
        let storage = try makeStorage([UInt8](repeating: 0x00, count: 100), budgets: budgets)

        try storage.overwrite(range: 10..<14, with: [1, 2, 3, 4])
        try storage.overwrite(range: 50..<56, with: [5, 6, 7, 8, 9, 10])   // trips the fold

        XCTAssertTrue(storage.canPatchInPlace, "overwrites never shift offsets")
        XCTAssertEqual(storage.changedRanges, [10..<14, 50..<56])
        XCTAssertTrue(storage.isDirty)
        XCTAssertEqual(try storage.read(at: 10, length: 4), [1, 2, 3, 4])
        XCTAssertEqual(try storage.read(at: 50, length: 6), [5, 6, 7, 8, 9, 10])
    }
}
