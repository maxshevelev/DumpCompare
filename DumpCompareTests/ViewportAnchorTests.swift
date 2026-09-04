import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.2: an appearance change re-lays the dump out, and the content stays where
/// the user was looking — the row at the middle of the viewport is still there
/// afterwards. For the row-height factor, for the font family, and for the font
/// size, which Zoom In / Zoom Out move a point at a time.
///
/// `HexViewAppearanceTests` pins this for a lone hex view. These tests pin it
/// for the thing the user actually has in front of them — a pane inside a
/// window, and two panes locked together — because that is where it broke: the
/// panes' locked scrolling copied *pixels* between them, and for the span of an
/// appearance change the two panes are not measured the same way, so a copied
/// pixel position pointed at different bytes. Both panes then re-centred on
/// where they had been pushed to, and walked away from where the user was: 235
/// rows, 60 000 bytes down a file.
@MainActor
final class ViewportAnchorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppearanceSettings.resetToDefaults()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    override func tearDown() {
        AppearanceSettings.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A controller in a real window, one pane or two, scrolled to `offset`.
    private func makeWindow(companion: Bool, scrolledTo offset: CGFloat)
    throws -> (MainViewController, NSWindow) {
        let bytes = [UInt8](repeating: 0xAB, count: 65536)
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: try tempFile(bytes))
        if companion {
            try controller.windowModel.pane2.open(url: try tempFile(bytes))
            controller.apply(mode: .comparison)
        } else {
            controller.apply(mode: .singleFile)
        }
        window.layoutIfNeeded()
        addTeardownBlock { [weak controller] in
            controller?.windowModel.pane1.close()
            controller?.windowModel.pane2.close()
        }

        let scrollView = try paneViews(window)[0].scrollView
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func paneViews(_ window: NSWindow) throws -> [FilePaneView] {
        descendants(of: try XCTUnwrap(window.contentView), FilePaneView.self)
    }

    /// The offset of the row sitting at the middle of a pane's viewport — what
    /// the user is looking at, in bytes rather than in pixels.
    private func centreOffset(of paneView: FilePaneView) throws -> UInt64 {
        let hexView = try XCTUnwrap(paneView.scrollView.documentView as? HexView)
        let row = Int(paneView.scrollView.contentView.bounds.midY / hexView.hexLayout.rowHeight)
        return UInt64(row) * 16
    }

    /// Applies `change`, lets the observers run, and reports every pane's
    /// centre before and after.
    private func centresAcross(_ change: () -> Void, in window: NSWindow)
    throws -> (before: [UInt64], after: [UInt64]) {
        let panes = try paneViews(window)
        let before = try panes.map { try centreOffset(of: $0) }
        change()
        // The appearance observers are delivered on the main queue.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        window.layoutIfNeeded()
        return (before, try panes.map { try centreOffset(of: $0) })
    }

    private func zoomIn() { AppearanceSettings.zoom(by: AppearanceSettings.fontSizeStep) }
    private func zoomOut() { AppearanceSettings.zoom(by: -AppearanceSettings.fontSizeStep) }
    private func setRowHeight(_ scale: CGFloat) {
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily, rowHeightScale: scale)
    }

    // MARK: - Two panes

    /// The regression, at the position that showed it worst: deep in a file,
    /// where a proportional error is a screenful.
    func testZoomKeepsBothPanesWhereTheUserWasDeepInTheFile() throws {
        let (_, window) = try makeWindow(companion: true, scrolledTo: 60000)

        let zoomedIn = try centresAcross({ self.zoomIn() }, in: window)
        XCTAssertEqual(zoomedIn.after, zoomedIn.before, "a zoom moves no content")

        let zoomedOut = try centresAcross({ self.zoomOut() }, in: window)
        XCTAssertEqual(zoomedOut.after, zoomedOut.before)
    }

    /// And the panes are still locked to each other afterwards, which is the
    /// other half of the guarantee: holding the centre by letting the two drift
    /// apart would trade one broken rule for another (§9).
    func testTheTwoPanesStayInLockStepAcrossAZoom() throws {
        let (_, window) = try makeWindow(companion: true, scrolledTo: 12000)
        let panes = try paneViews(window)
        XCTAssertEqual(try centreOffset(of: panes[0]), try centreOffset(of: panes[1]),
                       "the premise: locked before the change")

        let centres = try centresAcross({ self.zoomIn() }, in: window)

        XCTAssertEqual(centres.after, centres.before)
        XCTAssertEqual(centres.after[0], centres.after[1], "and still locked after it")
        XCTAssertEqual(panes[0].scrollView.contentView.bounds.origin.y,
                       panes[1].scrollView.contentView.bounds.origin.y, accuracy: 1,
                       "to the pixel, since the two are measured the same way again")
    }

    /// The same for the other two appearance settings: the row-height factor
    /// and the font family change the row pitch just as the size does.
    func testRowHeightAndFontFamilyKeepBothPanesWhereTheUserWas() throws {
        let (_, window) = try makeWindow(companion: true, scrolledTo: 30000)

        let taller = try centresAcross({ self.setRowHeight(1.0) }, in: window)
        XCTAssertEqual(taller.after, taller.before, "a taller row moves no content")

        let family = try XCTUnwrap(AppearanceSettings.monospacedFontFamilies().first)
        let swapped = try centresAcross({
            AppearanceSettings.set(fontFamily: family,
                                   rowHeightScale: AppearanceSettings.rowHeightScale)
        }, in: window)
        XCTAssertEqual(swapped.after, swapped.before, "nor does another font")
    }

    /// Locked scrolling itself is untouched: a scroll in one pane still moves
    /// the other, which is what the appearance guard must not cost (§9).
    func testAScrollStillMovesTheOtherPane() throws {
        let (_, window) = try makeWindow(companion: true, scrolledTo: 0)
        let panes = try paneViews(window)

        panes[0].scrollView.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        panes[0].scrollView.reflectScrolledClipView(panes[0].scrollView.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(panes[1].scrollView.contentView.bounds.origin.y, 4000, accuracy: 1,
                       "the panes follow each other")
    }

    // MARK: - One pane

    /// Single-file mode never had the bug — there is no second pane to copy
    /// pixels from — and stays covered, so a future change to the anchor
    /// cannot break it quietly.
    func testOnePaneKeepsTheCentreAcrossEveryAppearanceChange() throws {
        let (_, window) = try makeWindow(companion: false, scrolledTo: 60000)

        let zoomed = try centresAcross({ self.zoomIn() }, in: window)
        XCTAssertEqual(zoomed.after, zoomed.before)

        let taller = try centresAcross({ self.setRowHeight(1.0) }, in: window)
        XCTAssertEqual(taller.after, taller.before)
    }
}
