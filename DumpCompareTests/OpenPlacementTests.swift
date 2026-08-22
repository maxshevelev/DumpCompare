import XCTest
@testable import DumpCompare

/// The pure File > Open placement decision (§4.1 rules 1–3): which pane the
/// first selected file lands in, whether a second one opens beside it, and how
/// many were ignored.
///
/// One test per rule over a table of cases, rather than one test per case: the
/// three rules are the branches of a single `switch`, and the interesting part
/// of each is how its answer changes across the inputs. Splitting them made the
/// rule-3 case with `active: 0` a test that a hardcoded `0` would pass; here
/// both actives sit in one table and the difference between them is the
/// assertion.
final class OpenPlacementTests: XCTestCase {
    private func plan(active: Int = 0, pane1: Bool, pane2: Bool, count: Int) -> OpenPlacement.Result {
        OpenPlacement.plan(activePaneIndex: active, pane1Open: pane1, pane2Open: pane2, fileCount: count)
    }

    private struct Case {
        let name: String
        let active: Int
        let files: Int
        let firstFilePane: Int?
        let openSecond: Bool
        let ignored: Int
    }

    private func check(_ cases: [Case], pane1: Bool, pane2: Bool) {
        for c in cases {
            let r = plan(active: c.active, pane1: pane1, pane2: pane2, count: c.files)
            XCTAssertEqual(r.firstFilePane, c.firstFilePane, "\(c.name): first file's pane")
            XCTAssertEqual(r.openSecond, c.openSecond, "\(c.name): whether a second pane opens")
            XCTAssertEqual(r.ignoredCount, c.ignored, "\(c.name): files ignored")
        }
    }

    /// Rule 1: nothing open. The first file takes pane 1, a second takes pane 2,
    /// and anything beyond the two is ignored with a count to report.
    func testWithNoPanesOccupiedTheFirstTwoFilesFillBothPanes() {
        check([
            Case(name: "no files at all places nothing",
                 active: 0, files: 0, firstFilePane: nil, openSecond: false, ignored: 0),
            Case(name: "one file opens pane 1 alone",
                 active: 0, files: 1, firstFilePane: 0, openSecond: false, ignored: 0),
            Case(name: "two files open both panes",
                 active: 0, files: 2, firstFilePane: 0, openSecond: true, ignored: 0),
            Case(name: "five files open two and ignore three",
                 active: 0, files: 5, firstFilePane: 0, openSecond: true, ignored: 3),
        ], pane1: false, pane2: false)
    }

    /// Rule 2: pane 1 occupied. The file goes to the empty pane beside it, and
    /// there is only ever room for one.
    func testWithPane1OccupiedTheFileGoesToPane2() {
        check([
            Case(name: "one file opens pane 2",
                 active: 0, files: 1, firstFilePane: 1, openSecond: false, ignored: 0),
            Case(name: "three files open one and ignore two",
                 active: 0, files: 3, firstFilePane: 1, openSecond: false, ignored: 2),
        ], pane1: true, pane2: false)
    }

    /// Rule 3: both occupied. The file replaces whichever pane is active — the
    /// two rows with different `active` values are what make this a test of
    /// `activePaneIndex` rather than of a constant.
    func testWithBothPanesOccupiedTheFileReplacesTheActiveOne() {
        check([
            Case(name: "pane 1 active, the file replaces pane 1",
                 active: 0, files: 1, firstFilePane: 0, openSecond: false, ignored: 0),
            Case(name: "pane 2 active, the file replaces pane 2",
                 active: 1, files: 1, firstFilePane: 1, openSecond: false, ignored: 0),
            Case(name: "four files replace one and ignore three",
                 active: 1, files: 4, firstFilePane: 1, openSecond: false, ignored: 3),
        ], pane1: true, pane2: true)
    }
}
