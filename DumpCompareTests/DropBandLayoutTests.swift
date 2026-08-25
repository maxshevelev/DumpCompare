import XCTest
@testable import DumpCompare

/// §22.4 the drop-band geometry, tested at several pane heights: which band a
/// top-down y maps to, and the strip-height clamp (25 % of the half, 48…120 pt).
/// Pure — no view, so the hit-testing is pinned without a window.
final class DropBandLayoutTests: XCTestCase {
    /// A point in the top strip maps to Insert at Start, including the strip's
    /// last row.
    func testTopStripMapsToInsertAtStart() {
        let layout = DropBandLayout(halfHeight: 400)  // strip = 100
        XCTAssertEqual(layout.band(atTopDownY: 0), .insertAtStart)
        XCTAssertEqual(layout.band(atTopDownY: layout.stripHeight - 1), .insertAtStart)
    }

    /// A point in the middle maps to Replace.
    func testMiddleMapsToReplace() {
        let layout = DropBandLayout(halfHeight: 400)
        XCTAssertEqual(layout.band(atTopDownY: layout.halfHeight / 2), .replace)
        // The replace band's first and last rows.
        XCTAssertEqual(layout.band(atTopDownY: layout.stripHeight), .replace)
        XCTAssertEqual(layout.band(atTopDownY: layout.halfHeight - layout.stripHeight - 1), .replace)
    }

    /// A point in the bottom strip maps to Append at End, including the half's
    /// last row.
    func testBottomStripMapsToAppendAtEnd() {
        let layout = DropBandLayout(halfHeight: 400)
        XCTAssertEqual(layout.band(atTopDownY: layout.halfHeight - 1), .appendAtEnd)
        XCTAssertEqual(layout.band(atTopDownY: layout.halfHeight - layout.stripHeight), .appendAtEnd)
    }

    /// Outside the half, no band: a drop outside any band changes nothing.
    func testOutsideTheHalfIsNoBand() {
        let layout = DropBandLayout(halfHeight: 400)
        XCTAssertNil(layout.band(atTopDownY: -1))
        XCTAssertNil(layout.band(atTopDownY: layout.halfHeight))
    }

    /// The strip height is 25 % of the half, clamped to 48…120 pt: a short
    /// half gets the 48 pt minimum, a tall half the 120 pt maximum, and a
    /// middle half exactly 25 %.
    func testStripHeightIsClamped() {
        XCTAssertEqual(DropBandLayout(halfHeight: 100).stripHeight, 48,
                       "a short half clamps up to the 48 pt minimum")
        XCTAssertEqual(DropBandLayout(halfHeight: 1000).stripHeight, 120,
                       "a tall half clamps down to the 120 pt maximum")
        XCTAssertEqual(DropBandLayout(halfHeight: 400).stripHeight, 100,
                       "a middle half is exactly 25 % of the half's height")
    }

    /// At several pane heights the bands always tile the half exactly: the
    /// strip rows plus the replace rows equal the half's height, with no gap
    /// and no overlap between the bands.
    func testTheBandsTileTheHalfAtSeveralHeights() {
        for halfHeight in [100.0, 192.0, 400.0, 600.0, 1000.0] {
            let layout = DropBandLayout(halfHeight: halfHeight)
            let strip = layout.stripHeight
            // Every row in the half maps to exactly one band.
            for y in stride(from: 0.0, to: halfHeight, by: 1) {
                XCTAssertNotNil(layout.band(atTopDownY: y),
                                "row \(y) of a \(halfHeight) half maps to a band")
            }
            // The band boundaries are consistent: the first strip row is
            // insert, the first replace row is replace, the first append row
            // is append.
            XCTAssertEqual(layout.band(atTopDownY: 0), .insertAtStart)
            XCTAssertEqual(layout.band(atTopDownY: strip), .replace)
            XCTAssertEqual(layout.band(atTopDownY: halfHeight - strip), .appendAtEnd)
        }
    }
}
