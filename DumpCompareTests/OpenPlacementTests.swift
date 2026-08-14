import XCTest
@testable import DumpCompare

/// M6 tests for the pure File > Open placement decision (§4.1 rules 1–3),
/// including the notification counts for ignored files.
final class OpenPlacementTests: XCTestCase {
    private func plan(active: Int = 0, pane1: Bool, pane2: Bool, count: Int) -> OpenPlacement.Result {
        OpenPlacement.plan(activePaneIndex: active, pane1Open: pane1, pane2Open: pane2, fileCount: count)
    }

    // MARK: - Rule 1: no panes occupied

    func testBothEmptySingleFileOpensPane1() {
        let r = plan(pane1: false, pane2: false, count: 1)
        XCTAssertEqual(r.firstFilePane, 0)
        XCTAssertFalse(r.openSecond)
        XCTAssertEqual(r.ignoredCount, 0)
    }

    func testBothEmptyTwoFilesOpenBothPanes() {
        let r = plan(pane1: false, pane2: false, count: 2)
        XCTAssertEqual(r.firstFilePane, 0)
        XCTAssertTrue(r.openSecond)
        XCTAssertEqual(r.ignoredCount, 0)
    }

    func testBothEmptyExtrasIgnoredAndNotified() {
        let r = plan(pane1: false, pane2: false, count: 5)
        XCTAssertEqual(r.firstFilePane, 0)
        XCTAssertTrue(r.openSecond)
        XCTAssertEqual(r.ignoredCount, 3)
    }

    // MARK: - Rule 2: only pane 1 occupied

    func testPane1OnlyOpensPane2() {
        let r = plan(pane1: true, pane2: false, count: 1)
        XCTAssertEqual(r.firstFilePane, 1)
        XCTAssertFalse(r.openSecond)
        XCTAssertEqual(r.ignoredCount, 0)
    }

    func testPane1OnlyExtrasIgnored() {
        let r = plan(pane1: true, pane2: false, count: 3)
        XCTAssertEqual(r.firstFilePane, 1)
        XCTAssertEqual(r.ignoredCount, 2)
    }

    // MARK: - Rule 3: both panes occupied — replace the active pane

    func testBothOccupiedReplacesActivePane() {
        let r = plan(active: 0, pane1: true, pane2: true, count: 1)
        XCTAssertEqual(r.firstFilePane, 0)
        XCTAssertFalse(r.openSecond)
        XCTAssertEqual(r.ignoredCount, 0)
    }

    func testBothOccupiedActivePane1() {
        let r = plan(active: 1, pane1: true, pane2: true, count: 1)
        XCTAssertEqual(r.firstFilePane, 1)
        XCTAssertEqual(r.ignoredCount, 0)
    }

    func testBothOccupiedExtrasIgnored() {
        let r = plan(active: 1, pane1: true, pane2: true, count: 4)
        XCTAssertEqual(r.firstFilePane, 1)
        XCTAssertEqual(r.ignoredCount, 3)
    }

    func testNoFilesNeverPlaces() {
        let r = plan(pane1: false, pane2: false, count: 0)
        XCTAssertNil(r.firstFilePane)
        XCTAssertFalse(r.openSecond)
        XCTAssertEqual(r.ignoredCount, 0)
    }
}
