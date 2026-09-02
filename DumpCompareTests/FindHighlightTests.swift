import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §11 + §6: the dump greys every occurrence of the search pattern, in both
/// columns, under the difference fill (`Design/FIND_HIGHLIGHT_PLAN.md`).
///
/// Asserted by rendering: the grey is a background, and the only way to know a
/// background was painted where it should be — and *not* over the orange that
/// outranks it — is to look at the pixels.
@MainActor
final class FindHighlightTests: XCTestCase {
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        isolatedSuiteName = "FindHighlightTests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)
        FindHistoryStore.defaults = isolatedDefaults
        FindBarView.defaults = isolatedDefaults
        FilePaneView.defaults = isolatedDefaults
    }

    override func tearDown() {
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        FilePaneView.defaults = .standard
        isolatedDefaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeController(_ bytes: [UInt8], _ companion: [UInt8]? = nil)
        throws -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: try tempFile(bytes))
        if let companion {
            try controller.windowModel.pane2.open(url: try tempFile(companion))
            controller.apply(mode: .comparison)
        } else {
            controller.apply(mode: .singleFile)
        }
        window.layoutIfNeeded()
        addTeardownBlock { [weak controller] in
            controller?.windowModel.pane1.close()
            controller?.windowModel.pane2.close()
        }
        return (controller, window)
    }

    /// Runs a search through the real bar and waits for the set to land.
    private func search(_ pattern: String, in controller: MainViewController,
                        _ window: NSWindow) throws {
        controller.findPattern()
        let bar = try descendant(FindBarView.self, of: window.contentView!)
        let combo = try XCTUnwrap(descendants(of: bar, NSComboBox.self).first)
        combo.stringValue = pattern
        bar.pressFindForTests(.forward)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.matchSet != nil },
                      "the scan must land a set")
        window.layoutIfNeeded()
    }

    private func hexView(_ window: NSWindow, pane: Int = 0) throws -> HexView {
        let panes = descendants(of: window.contentView!, FilePaneView.self)
        return try XCTUnwrap(descendants(of: panes[pane], HexView.self).first)
    }

    // MARK: - Reading the pixels

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "no bitmap rep")
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The mean colour inside a point-space rect — the shape of assertion a
    /// *background* wants, where a single pixel could be a glyph's ink.
    private func meanColor(_ rep: NSBitmapImageRep, in rect: NSRect, scale: CGFloat)
        -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let startX = max(0, Int(floor(rect.minX * scale)))
        let endX = min(rep.pixelsWide - 1, Int(ceil(rect.maxX * scale)))
        let startY = max(0, Int(floor(rect.minY * scale)))
        let endY = min(rep.pixelsHigh - 1, Int(ceil(rect.maxY * scale)))
        guard endX >= startX, endY >= startY else { return (0, 0, 0) }
        var sum = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))
        var count = CGFloat(0)
        for y in startY...endY {
            for x in startX...endX {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sum = (sum.r + c.redComponent, sum.g + c.greenComponent, sum.b + c.blueComponent)
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (sum.r / count, sum.g / count, sum.b / count)
    }

    private func cellRects(_ view: HexView, row: Int, column: Int) -> (hex: NSRect, ascii: NSRect) {
        let layout = view.hexLayout
        let hex = layout.hexByteFrame(row: row, column: column)
        let ascii = NSRect(x: layout.asciiX(column: column), y: hex.minY,
                           width: layout.charWidth, height: layout.rowHeight)
        return (hex, ascii)
    }

    /// How far two mean colours are apart — appearance-agnostic, so the same
    /// assertion holds in light and dark.
    private func distance(_ a: (r: CGFloat, g: CGFloat, b: CGFloat),
                          _ b: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
    }

    // MARK: - Tests

    /// Every occurrence gets a background, in the hex column and in the decoded
    /// text — and the bytes between them do not.
    func testEveryMatchIsFilledInBothColumns() throws {
        // Matches at 0x00 and 0x04; 0x02 is not a match.
        let bytes: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xBB, 0x33, 0x44]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)

        let matched = cellRects(view, row: 0, column: 4)
        let unmatched = cellRects(view, row: 0, column: 2)
        var rep = try render(view)
        var scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let matchedBefore = meanColor(rep, in: matched.hex, scale: scale)
        let matchedAsciiBefore = meanColor(rep, in: matched.ascii, scale: scale)
        let unmatchedBefore = meanColor(rep, in: unmatched.hex, scale: scale)

        try search("AA BB", in: controller, window)

        rep = try render(view)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(distance(meanColor(rep, in: matched.hex, scale: scale), matchedBefore),
                             0.05, "the second occurrence must be filled in the hex column")
        XCTAssertGreaterThan(distance(meanColor(rep, in: matched.ascii, scale: scale),
                                      matchedAsciiBefore),
                             0.05, "and in the decoded-text column")
        XCTAssertLessThan(distance(meanColor(rep, in: unmatched.hex, scale: scale), unmatchedBefore),
                          0.02, "a byte that is not part of a match is left alone")
    }

    /// The fill ends with the session: nothing on screen keeps claiming a
    /// search is active after the bar closes.
    func testTheFillGoesWithTheSession() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xBB]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        // The *second* occurrence: Find Next selects the first, and a selection
        // outlives the bar, so only an unselected match isolates the grey.
        let cell = cellRects(view, row: 0, column: 4).hex

        var rep = try render(view)
        var scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let before = meanColor(rep, in: cell, scale: scale)

        try search("AA BB", in: controller, window)
        rep = try render(view)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(distance(meanColor(rep, in: cell, scale: scale), before), 0.05,
                             "filled while the search is on")

        let bar = try descendant(FindBarView.self, of: window.contentView!)
        let done = try XCTUnwrap(descendants(of: bar, NSButton.self)
            .first { $0.accessibilityLabel() == "Done" })
        done.performClick(nil)
        window.layoutIfNeeded()

        rep = try render(view)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertLessThan(distance(meanColor(rep, in: cell, scale: scale), before), 0.02,
                          "the fill goes when the session ends")
    }

    /// §6's layering: the grey sits *under* the difference fill. Telling two
    /// dumps apart is what the app is for, so a matched byte that also differs
    /// must still read as a difference.
    func testTheDifferenceFillWinsOverTheMatchFill() throws {
        // Byte 5 differs between the files and sits inside the *second* match,
        // the one Find Next does not select — a selection fill over it would
        // hide the very layering this test is about.
        let left: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xBB]
        let right: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xCC]
        let (controller, window) = try makeController(left, right)
        let view = try hexView(window)
        let differing = cellRects(view, row: 0, column: 5).hex
        let matchedOnly = cellRects(view, row: 0, column: 4).hex

        try search("AA BB", in: controller, window)
        let rep = try render(view)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let differingColor = meanColor(rep, in: differing, scale: scale)
        let matchedColor = meanColor(rep, in: matchedOnly, scale: scale)

        // Orange separates red from blue; the match grey is neutral, so a cell
        // that kept its difference reads warm and one that is only matched does
        // not.
        XCTAssertGreaterThan(differingColor.r - differingColor.b, 0.05,
                             "a differing byte inside a match keeps its orange")
        XCTAssertLessThan(matchedColor.r - matchedColor.b, 0.02,
                          "a byte that is only matched wears the neutral grey")
    }

    /// A match crossing a row boundary is filled on both rows — the case a
    /// 16-byte grid creates on almost every screen.
    func testAMatchStraddlingARowBoundaryIsFilledOnBothRows() throws {
        var bytes = [UInt8](repeating: 0x11, count: 48)
        // A four-byte match at 0x0E: two bytes on row 0, two on row 1.
        bytes.replaceSubrange(14..<18, with: [0xDE, 0xAD, 0xBE, 0xEF])
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        let tail = cellRects(view, row: 0, column: 15).hex
        let head = cellRects(view, row: 1, column: 0).hex

        var rep = try render(view)
        var scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let tailBefore = meanColor(rep, in: tail, scale: scale)
        let headBefore = meanColor(rep, in: head, scale: scale)

        try search("DE AD BE EF", in: controller, window)
        rep = try render(view)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(distance(meanColor(rep, in: tail, scale: scale), tailBefore), 0.05,
                             "the part of the match on the first row")
        XCTAssertGreaterThan(distance(meanColor(rep, in: head, scale: scale), headBefore), 0.05,
                             "and the part on the next row")
    }
}
