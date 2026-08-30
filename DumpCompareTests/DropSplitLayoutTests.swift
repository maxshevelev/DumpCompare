import XCTest
@testable import DumpCompare

/// §4.3: the single-file drop overlay is divided the way the panes are.
///
/// The direction is a setting and can change while the overlay is on screen.
/// With one file open there is no comparison for the controller to re-apply it
/// to, so nothing else rebuilds this split — read once at construction, it went
/// on offering the old arrangement: a drop overlay divided side by side over
/// panes that had been told to stack.
@MainActor
final class DropSplitLayoutTests: XCTestCase {
    private var savedIsVertical: Bool?

    override func setUp() {
        super.setUp()
        savedIsVertical = LayoutSettings.isVertical
    }

    override func tearDown() {
        if let savedIsVertical {
            LayoutSettings.set(isVertical: savedIsVertical)
        }
        super.tearDown()
    }

    private func makeDropView() -> SingleFileDropView {
        SingleFileDropView(paneView: FilePaneView(viewModel: PaneViewModel()))
    }

    /// Built while the layout is vertical, the halves sit side by side.
    func testItIsBuiltAlongTheCurrentLayout() {
        LayoutSettings.set(isVertical: true)
        XCTAssertTrue(makeDropView().isSplitVerticallyForTesting)

        LayoutSettings.set(isVertical: false)
        XCTAssertFalse(makeDropView().isSplitVerticallyForTesting)
    }

    /// And it follows the setting afterwards. This is the bug: a tab left in
    /// single-file mode kept the split it was born with, so dragging a pane onto
    /// it offered halves at right angles to the panes.
    func testItFollowsALayoutChangeWhileOnScreen() {
        LayoutSettings.set(isVertical: true)
        let view = makeDropView()
        XCTAssertTrue(view.isSplitVerticallyForTesting, "the premise")

        LayoutSettings.set(isVertical: false)

        XCTAssertFalse(view.isSplitVerticallyForTesting,
                       "the overlay must be divided the way the panes are")
    }

    /// And back again, so the change is not a one-way door.
    func testItFollowsTheLayoutBothWays() {
        LayoutSettings.set(isVertical: false)
        let view = makeDropView()

        LayoutSettings.set(isVertical: true)
        XCTAssertTrue(view.isSplitVerticallyForTesting)

        LayoutSettings.set(isVertical: false)
        XCTAssertFalse(view.isSplitVerticallyForTesting)
    }
}
