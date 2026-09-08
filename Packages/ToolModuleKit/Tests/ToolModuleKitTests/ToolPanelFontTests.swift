import AppKit
import XCTest
@testable import ToolModuleKit

/// The size a panel draws at: where it comes from, what it does at the ends of
/// the zoom's range, and the two measurements taken from it.
@MainActor
final class ToolPanelFontTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ToolPanelFont.zoomSizeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ToolPanelFont.zoomSizeKey)
        super.tearDown()
    }

    private func setZoom(_ size: CGFloat) {
        UserDefaults.standard.set(Double(size), forKey: ToolPanelFont.zoomSizeKey)
    }

    /// Nothing stored is the app's own default zoom — and that is bigger than
    /// the 11 points the panels used to be laid out at, which is the point of
    /// reading the zoom at all.
    func testWithNothingStoredThePanelIsBiggerThanItWasLaidOutAt() {
        XCTAssertEqual(ToolPanelFont.size, ToolPanelFont.defaultSize)
        XCTAssertGreaterThan(ToolPanelFont.size, ToolPanelFont.designSize)
    }

    /// The stored zoom is the size, so a panel and the dump beside it read at
    /// one size rather than two.
    func testTheSizeFollowsTheStoredZoom() {
        setZoom(18)
        XCTAssertEqual(ToolPanelFont.size, 18)
        XCTAssertEqual(ToolPanelFont.body().pointSize, 18)
        XCTAssertEqual(ToolPanelFont.monospacedDigits().pointSize, 18)
        XCTAssertEqual(ToolPanelFont.title().pointSize, 19)
    }

    /// A size from outside the zoom's range — an older build's defaults, a
    /// hand-edited plist — is clamped rather than drawn at.
    func testASizeOutsideTheRangeIsClamped() {
        setZoom(400)
        XCTAssertEqual(ToolPanelFont.size, ToolPanelFont.sizeRange.upperBound)
        setZoom(1)
        XCTAssertEqual(ToolPanelFont.size, ToolPanelFont.sizeRange.lowerBound)
    }

    /// A row is taller than the text in it at every size the zoom offers —
    /// this is what `.small` (a fixed 17 points) stops being true for.
    func testARowIsTallerThanItsTextAtEverySize() {
        for size in stride(from: ToolPanelFont.sizeRange.lowerBound,
                           through: ToolPanelFont.sizeRange.upperBound,
                           by: 1) {
            setZoom(size)
            let font = ToolPanelFont.body()
            let ink = font.ascender - font.descender
            XCTAssertGreaterThan(ToolPanelFont.rowHeight, ink,
                                 "a row at \(size) points clips its own text")
            XCTAssertGreaterThanOrEqual(ToolPanelFont.headerHeight, 17,
                                        "a header never gets shorter than AppKit's own")
        }
    }

    /// A width chosen for text at the design size grows with the size — a
    /// column that does not is a column whose text no longer fits it.
    func testAWidthScalesWithTheSize() {
        setZoom(ToolPanelFont.designSize)
        XCTAssertEqual(ToolPanelFont.scaled(96), 96)
        XCTAssertEqual(ToolPanelFont.detailLabelWidth, 104)

        setZoom(ToolPanelFont.designSize * 2)
        XCTAssertEqual(ToolPanelFont.scaled(96), 192)
        XCTAssertEqual(ToolPanelFont.detailLabelWidth, 208)
    }

    /// The zoom's own notification is what a panel listens to, and the handler
    /// runs on the main queue where a view can be touched.
    func testAZoomReachesTheObserver() {
        var told = 0
        let token = ToolPanelFont.observeZoom { told += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(
            name: ToolPanelFont.zoomDidChangeNotification, object: nil
        )
        XCTAssertEqual(told, 1)
    }
}
