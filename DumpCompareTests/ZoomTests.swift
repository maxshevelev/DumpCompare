import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.2 Zoom In / Zoom Out: the hex font size from the View menu, one point at
/// a time, applied live to every open dump.
///
/// It is the *same* app-wide setting the Appearance tab holds — the menu is a
/// fast way to it, not a second preference — so these tests are about the step,
/// the ends of the range, and the fact that the dump follows.
@MainActor
final class ZoomTests: XCTestCase {
    private var delegate: AppDelegate!

    override func setUp() {
        super.setUp()
        AppearanceSettings.resetToDefaults()
        delegate = AppDelegate()
    }

    override func tearDown() {
        delegate = nil
        AppearanceSettings.resetToDefaults()
        super.tearDown()
    }

    // MARK: - The step

    /// One press, one point — the same point the Settings stepper steps, so
    /// the menu never lands between the values that tab offers.
    func testAZoomStepsOnePoint() {
        let start = AppearanceSettings.fontSize

        delegate.increaseHexFontSize(nil)
        XCTAssertEqual(AppearanceSettings.fontSize, start + 1, accuracy: 0.0001)

        delegate.decreaseHexFontSize(nil)
        delegate.decreaseHexFontSize(nil)
        XCTAssertEqual(AppearanceSettings.fontSize, start - 1, accuracy: 0.0001)
    }

    /// Zooming says nothing about the rest of the appearance, so nothing else
    /// moves — a zoom is not a way to reset the font or the row pitch.
    func testAZoomLeavesTheRestOfTheAppearanceAlone() throws {
        let family = try XCTUnwrap(AppearanceSettings.monospacedFontFamilies().first)
        AppearanceSettings.set(fontFamily: family, rowHeightScale: 0.9)

        delegate.increaseHexFontSize(nil)

        XCTAssertEqual(AppearanceSettings.fontFamily, family)
        XCTAssertEqual(AppearanceSettings.rowHeightScale, 0.9, accuracy: 0.0001)
    }

    /// Each press is one change, so open views re-lay out once rather than
    /// twice per keystroke.
    func testAZoomNotifiesOnce() {
        var notified = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        delegate.increaseHexFontSize(nil)

        XCTAssertEqual(notified, 1)
    }

    // MARK: - The ends of the range

    /// The size stays inside the range the Settings stepper offers: pressing
    /// on at either end changes nothing, and nothing is posted for a change
    /// that did not happen.
    func testZoomStopsAtBothEndsOfTheRange() {
        var notified = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for _ in 0..<40 { delegate.increaseHexFontSize(nil) }
        XCTAssertEqual(AppearanceSettings.fontSize,
                       AppearanceSettings.fontSizeRange.upperBound, accuracy: 0.0001)
        let atTop = notified
        delegate.increaseHexFontSize(nil)
        XCTAssertEqual(notified, atTop, "a press that changes nothing posts nothing")

        for _ in 0..<40 { delegate.decreaseHexFontSize(nil) }
        XCTAssertEqual(AppearanceSettings.fontSize,
                       AppearanceSettings.fontSizeRange.lowerBound, accuracy: 0.0001)
        let atBottom = notified
        delegate.decreaseHexFontSize(nil)
        XCTAssertEqual(notified, atBottom)
    }

    /// And the item dims there, so the shortcut beeps instead of silently
    /// doing nothing.
    func testTheItemsDimAtTheEnds() throws {
        let viewMenu = MainMenu.makeViewMenu()
        let zoomIn = try XCTUnwrap(viewMenu.items.first { $0.title == "Zoom In" })
        let zoomOut = try XCTUnwrap(viewMenu.items.first { $0.title == "Zoom Out" })

        XCTAssertTrue(delegate.validateMenuItem(zoomIn), "13 pt is not either end")
        XCTAssertTrue(delegate.validateMenuItem(zoomOut))

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: AppearanceSettings.fontSizeRange.upperBound)
        XCTAssertFalse(delegate.validateMenuItem(zoomIn), "nothing to zoom into")
        XCTAssertTrue(delegate.validateMenuItem(zoomOut))

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily,
                               rowHeightScale: AppearanceSettings.rowHeightScale,
                               fontSize: AppearanceSettings.fontSizeRange.lowerBound)
        XCTAssertTrue(delegate.validateMenuItem(zoomIn))
        XCTAssertFalse(delegate.validateMenuItem(zoomOut))
    }

    // MARK: - The menu

    /// The shortcuts every document app uses for zoom, in the View menu, sent
    /// through the responder chain: the font size is one app-wide setting, so
    /// no window owns the command.
    func testTheViewMenuCarriesBothZoomItems() throws {
        let viewMenu = MainMenu.makeViewMenu()

        let zoomIn = try XCTUnwrap(viewMenu.items.first { $0.title == "Zoom In" })
        XCTAssertEqual(zoomIn.keyEquivalent, "=")
        XCTAssertEqual(zoomIn.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(zoomIn.action, #selector(AppDelegate.increaseHexFontSize(_:)))
        XCTAssertNil(zoomIn.target, "the app answers, whichever window is in front")

        let zoomOut = try XCTUnwrap(viewMenu.items.first { $0.title == "Zoom Out" })
        XCTAssertEqual(zoomOut.keyEquivalent, "-")
        XCTAssertEqual(zoomOut.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(zoomOut.action, #selector(AppDelegate.decreaseHexFontSize(_:)))
        XCTAssertNil(zoomOut.target)

        // Nothing else claims those keys.
        XCTAssertEqual(viewMenu.items.filter { $0.keyEquivalent == "=" }.count, 1)
        XCTAssertEqual(viewMenu.items.filter { $0.keyEquivalent == "-" }.count, 1)
    }

    /// The dispatch itself: with no target, the action walks the responder
    /// chain and the app delegate answers. That is the part a menu item's
    /// selector cannot prove on its own — a shortcut that reaches nobody does
    /// nothing at all.
    func testTheActionReachesTheAppThroughTheResponderChain() throws {
        try XCTSkipUnless(NSApp.delegate is AppDelegate,
                          "the test host's own delegate is what answers here")
        let start = AppearanceSettings.fontSize

        let handled = NSApp.sendAction(#selector(AppDelegate.increaseHexFontSize(_:)),
                                       to: nil, from: nil)

        XCTAssertTrue(handled)
        XCTAssertEqual(AppearanceSettings.fontSize, start + 1, accuracy: 0.0001)
    }

    // MARK: - The dump follows

    /// The point of the feature: an open dump re-lays out on the zoom, the way
    /// it does for the Appearance tab — same notification, same path.
    func testAnOpenDumpFollowsTheZoom() throws {
        let url = try tempFile([UInt8](repeating: 0xAB, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let pane = PaneViewModel()
        try pane.open(url: url)
        let hexView = HexView()
        hexView.dataSource = pane
        hexView.delegate = pane
        hexView.reloadData()

        let pitch = hexView.hexLayout.rowHeight
        let width = hexView.hexLayout.charWidth

        delegate.increaseHexFontSize(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertGreaterThan(hexView.hexLayout.rowHeight, pitch)
        XCTAssertGreaterThan(hexView.hexLayout.charWidth, width)

        delegate.decreaseHexFontSize(nil)
        delegate.decreaseHexFontSize(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertLessThan(hexView.hexLayout.charWidth, width)
        // The row pitch is the font's line height times the row factor, and
        // two adjacent sizes can round to the same whole point — 12 pt and
        // 13 pt both give 16 here. The glyph pitch is what always moves, so
        // the pitch is only held to "not taller".
        XCTAssertLessThanOrEqual(hexView.hexLayout.rowHeight, pitch)
    }
}
