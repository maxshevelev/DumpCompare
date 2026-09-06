import XCTest
@testable import UEFIFormat

/// The image as it would be with a change in it — what a checksum has to be
/// computed over, since a checksum describes bytes as they will be.
final class OverlayByteSourceTests: XCTestCase {
    private let base = [UInt8](0..<32)

    private func overlaid(_ patches: [OverlayByteSource.Patch]) -> ImageReader {
        ImageReader(OverlayByteSource(base: base, patches: patches))
    }

    func testAPatchIsSeenWhereItLies() {
        let reader = overlaid([.init(offset: 4, bytes: [0xAA, 0xBB])])

        XCTAssertEqual(reader.bytes(0..<8), [0, 1, 2, 3, 0xAA, 0xBB, 6, 7])
        XCTAssertEqual(reader.count, 32)
    }

    /// A read that starts or ends inside a patch gets the part of it that
    /// overlaps, and nothing outside.
    func testAReadThatStraddlesAPatchGetsBothSides() {
        let reader = overlaid([.init(offset: 8, bytes: [0xAA, 0xBB, 0xCC, 0xDD])])

        XCTAssertEqual(reader.bytes(6..<10), [6, 7, 0xAA, 0xBB])
        XCTAssertEqual(reader.bytes(10..<14), [0xCC, 0xDD, 12, 13])
        XCTAssertEqual(reader.bytes(9..<11), [0xBB, 0xCC])
    }

    func testAReadThatMissesEveryPatchIsTheImage() {
        let reader = overlaid([.init(offset: 20, bytes: [0xAA])])

        XCTAssertEqual(reader.bytes(0..<4), [0, 1, 2, 3])
    }

    /// Several patches, which is what an edit is: a component and the table
    /// that names it.
    func testSeveralPatchesAllShow() {
        let reader = overlaid([
            .init(offset: 0, bytes: [0xF0]),
            .init(offset: 31, bytes: [0xF1])
        ])

        XCTAssertEqual(reader.uint8(at: 0), 0xF0)
        XCTAssertEqual(reader.uint8(at: 31), 0xF1)
        XCTAssertEqual(reader.uint8(at: 15), 15)
    }

    /// The last one wins, so a caller can lay a correction over its own work
    /// rather than having to merge the two first.
    func testTheLastPatchWins() {
        let reader = overlaid([
            .init(offset: 4, bytes: [0xAA, 0xAA]),
            .init(offset: 5, bytes: [0xBB])
        ])

        XCTAssertEqual(reader.bytes(4..<6), [0xAA, 0xBB])
    }
}
