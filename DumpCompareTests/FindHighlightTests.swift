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

    /// How yellow a mean colour is: yellow lifts red and green together and
    /// drops blue, where the match grey and the paper are neutral.
    private func yellowness(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        min(c.r, c.g) - c.b
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
        // Matches at 0x00 and 0x06. The byte sampled as "not a match" is two
        // cells clear of both: the current match's bubble stands 2 pt off its
        // own cells and casts a shadow, so its immediate neighbour is not the
        // place to ask whether an unmatched byte was left alone.
        let bytes: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)

        let matched = cellRects(view, row: 0, column: 6)
        let unmatched = cellRects(view, row: 0, column: 3)
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

    /// A match straddling a row boundary keeps its grey on both rows while some
    /// *other* match is the current one — the case the indicator hides when it
    /// happens to sit on the straddling match itself.
    func testAStraddlingMatchThatIsNotCurrentIsStillGreyOnBothRows() throws {
        var bytes = [UInt8](repeating: 0x11, count: 48)
        bytes.replaceSubrange(0..<4, with: [0xDE, 0xAD, 0xBE, 0xEF])     // current match
        bytes.replaceSubrange(14..<18, with: [0xDE, 0xAD, 0xBE, 0xEF])   // straddles rows 0/1
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        let tail = cellRects(view, row: 0, column: 15).hex
        let head = cellRects(view, row: 1, column: 0).hex

        var rep = try render(view)
        var scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let tailBefore = meanColor(rep, in: tail, scale: scale)
        let headBefore = meanColor(rep, in: head, scale: scale)

        try search("DE AD BE EF", in: controller, window)
        XCTAssertEqual(controller.windowModel.pane1.currentMatchIndex, 0,
                       "the first match is the current one, not the straddling one")

        rep = try render(view)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(distance(meanColor(rep, in: tail, scale: scale), tailBefore), 0.05,
                             "the straddling match is grey on the first row")
        XCTAssertGreaterThan(distance(meanColor(rep, in: head, scale: scale), headBefore), 0.05,
                             "and on the next row")
    }

    // MARK: - The find indicator (the current match)

    /// The match the user is standing on is yellow; the others stay grey. That
    /// is the whole point of two states.
    func testTheCurrentMatchIsYellowAndTheOthersAreNot() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xBB]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)

        try search("AA BB", in: controller, window)
        let rep = try render(view)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let current = meanColor(rep, in: cellRects(view, row: 0, column: 0).hex, scale: scale)
        let other = meanColor(rep, in: cellRects(view, row: 0, column: 4).hex, scale: scale)

        XCTAssertGreaterThan(yellowness(current), 0.25,
                             "the current match wears the platform's find-indicator yellow")
        XCTAssertLessThan(yellowness(other), 0.05,
                          "every other occurrence stays the neutral grey")
        // The decoded-text column carries the indicator too.
        let currentAscii = meanColor(rep, in: cellRects(view, row: 0, column: 0).ascii, scale: scale)
        XCTAssertGreaterThan(yellowness(currentAscii), 0.25)
    }

    /// A step moves the yellow: the match left behind goes back to grey, so at
    /// most one occurrence ever claims to be the current one.
    func testTheIndicatorMovesWithTheStep() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xBB]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        try search("AA BB", in: controller, window)

        let bar = try descendant(FindBarView.self, of: window.contentView!)
        bar.pressFindForTests(.forward)
        window.layoutIfNeeded()

        let rep = try render(view)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertLessThan(yellowness(meanColor(rep, in: cellRects(view, row: 0, column: 0).hex,
                                               scale: scale)),
                          0.05, "the first match is no longer the current one")
        XCTAssertGreaterThan(yellowness(meanColor(rep, in: cellRects(view, row: 0, column: 4).hex,
                                                  scale: scale)),
                             0.25, "the second one is")
    }

    /// The outline is the selection mirror's own contour: it stands off the
    /// glyphs where a spacer allows it, instead of hugging them. A match
    /// starting at a word boundary therefore reaches into the gap before it.
    func testTheIndicatorStandsOffTheGlyphsLikeAMirroredSelection() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0x11, 0x22, 0xAA, 0xBB]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        try search("AA BB", in: controller, window)

        let layout = view.hexLayout
        let cell = layout.hexByteFrame(row: 0, column: 0)
        // The strip immediately left of the first byte: inside the contour's
        // padding, outside the cell.
        let padding = HexView.mirrorContourPadding
        let outside = CGRect(x: cell.minX - padding, y: cell.minY + 2,
                             width: padding, height: cell.height - 4)
        let rep = try render(view)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(yellowness(meanColor(rep, in: outside, scale: scale)), 0.2,
                             "the bubble reaches into the gap, as a mirrored selection would")
    }

    /// The plate's shadow shows on every side — a halo, so the plate is not cut
    /// out of the page — and is weighted to the bottom-right. `NSShadow` is not
    /// flipped with the view, so this is also the assertion that keeps the sign
    /// honest.
    ///
    /// Measured against a frame of the *same* view with no search running at
    /// all: absolute samples would be reading the neighbouring rows' glyphs,
    /// which are far darker than any shadow, and a rest-versus-hop difference
    /// would measure the change rather than the weighting.
    func testTheShadowHalosThePlateAndFallsToTheBottomRight() throws {
        XCTAssertGreaterThan(HexView.indicatorShadowOffset.width, 0)
        XCTAssertGreaterThan(HexView.indicatorShadowOffset.height, 0,
                             "down is positive: the shadow follows this view's flipped space")

        var bytes = [UInt8](repeating: 0x11, count: 48)
        bytes.replaceSubrange(18..<20, with: [0xAA, 0xBB])   // row 1, clear of both edges
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        try search("AA BB", in: controller, window)
        let pane = controller.windowModel.pane1

        let rest = try shadowWeight(view, pane: pane, row: 1, columns: 2...3, phase: 1)
        XCTAssertGreaterThan(rest.above, 0.004,
                             "the halo gives the plate an edge on the light side")
        XCTAssertGreaterThan(rest.left, 0.004)
        XCTAssertGreaterThan(rest.below, rest.above * 1.5,
                             "and the weight is below the plate, not above it")
        XCTAssertGreaterThan(rest.right, rest.left * 1.5,
                             "and to the right, not to the left")

        let top = try shadowWeight(view, pane: pane, row: 1, columns: 2...3, phase: 0.31)
        XCTAssertGreaterThan(top.below, rest.below,
                             "lifting the plate deepens the shadow under it")
    }

    /// How much darker each side of a plate's surroundings is than in a frame
    /// with no search running — the plate's own shadow, isolated.
    private func shadowWeight(_ view: HexView, pane: PaneViewModel,
                              row: Int, columns: ClosedRange<Int>, phase: CGFloat) throws
        -> (below: CGFloat, above: CGFloat, right: CGFloat, left: CGFloat) {
        let layout = view.hexLayout
        let plate = layout.hexByteFrame(row: row, column: columns.lowerBound)
            .union(layout.hexByteFrame(row: row, column: columns.upperBound))
        // Close in, where a halo meant to edge the plate has to show — the
        // reach is a couple of points, so this samples right against it.
        let gap: CGFloat = 1.5
        let patch = CGSize(width: 4, height: 2)
        let places = [
            "below": CGRect(x: plate.midX, y: plate.maxY + gap,
                            width: patch.width, height: patch.height),
            "above": CGRect(x: plate.midX, y: plate.minY - gap - patch.height,
                            width: patch.width, height: patch.height),
            "right": CGRect(x: plate.maxX + gap, y: plate.midY - patch.height / 2,
                            width: patch.width, height: patch.height),
            "left": CGRect(x: plate.minX - gap - patch.width, y: plate.midY - patch.height / 2,
                           width: patch.width, height: patch.height),
        ]

        func samples() throws -> [String: CGFloat] {
            view.needsDisplay = true
            let rep = try render(view)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            return places.mapValues { rect in
                let colour = meanColor(rep, in: rect, scale: scale)
                // `min(r, g)` isolates a shadow: it drops wherever the paper is
                // darkened and stays at 1 under the plate's own yellow (r == g
                // == 1), so a plate that has moved into the patch cannot be
                // mistaken for its shadow.
                return min(colour.r, colour.g)
            }
        }

        let set = try XCTUnwrap(pane.matchSet)
        let current = pane.currentMatchIndex
        pane.clearMatches()
        let baseline = try samples()
        pane.setMatches(set, current: current)
        view.indicatorBouncePhaseForTests = phase
        let lit = try samples()
        view.indicatorBouncePhaseForTests = nil
        return (below: baseline["below"]! - lit["below"]!,
                above: baseline["above"]! - lit["above"]!,
                right: baseline["right"]! - lit["right"]!,
                left: baseline["left"]! - lit["left"]!)
    }

    // MARK: - The bounce

    /// The hop: one clear jump and a small second one, and nothing at either
    /// end — the shape a thing that has been dropped has.
    func testTheHopRisesAndBouncesOnce() {
        XCTAssertEqual(HexView.indicatorLift(atPhase: 0), 0, accuracy: 0.0001,
                       "on the page before it starts")
        XCTAssertEqual(HexView.indicatorLift(atPhase: 1), 0, accuracy: 0.0001,
                       "and back on the page at the end")
        XCTAssertEqual(HexView.indicatorLift(atPhase: 0.31), 1, accuracy: 0.02,
                       "the top of the first jump")
        let second = HexView.indicatorLift(atPhase: 0.81)
        XCTAssertGreaterThan(second, 0.15, "there is a second, smaller jump")
        XCTAssertLessThan(second, 0.5)
        XCTAssertLessThan(HexView.indicatorLift(atPhase: 0.62), 0.1,
                          "and it touches down between the two")
    }

    /// Height is one idea, not three: the higher the bubble, the bigger it
    /// looks, the further it has risen, and the deeper and wider its shadow.
    func testHeightGrowsTheShadow() {
        let rest = HexView.indicatorElevation(atLift: 0)
        let top = HexView.indicatorElevation(atLift: 1)
        XCTAssertEqual(rest.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(rest.key.offset.width, HexView.indicatorShadowOffset.width,
                       accuracy: 0.0001, "at rest the shadow is the resting one")
        XCTAssertEqual(rest.key.offset.height, HexView.indicatorShadowOffset.height,
                       accuracy: 0.0001)
        XCTAssertGreaterThan(top.scale, rest.scale)
        XCTAssertEqual(rest.ambient.offset, .zero,
                       "the halo has no offset: it is the plate's edge on every side")
        XCTAssertGreaterThan(top.ambient.blur, rest.ambient.blur,
                             "the halo widens as the plate climbs")
        XCTAssertGreaterThan(top.key.blur, rest.key.blur,
                             "and the drop softens with it")
        XCTAssertGreaterThan(top.key.alpha, rest.key.alpha)
        XCTAssertGreaterThan(top.key.offset.width, rest.key.offset.width,
                             "the drop keeps falling to the right as it grows")
        XCTAssertGreaterThan(top.key.offset.height, rest.key.offset.height,
                             "and further down as the bubble climbs away from it")
        XCTAssertLessThan(top.key.offset.width, top.key.offset.height,
                          "biased downward more than sideways")
        XCTAssertLessThan(top.key.offset.height, 6,
                          "and short even at the top of the hop: a long shadow reads as a "
                          + "drop-shadow effect rather than as a small lift")
    }

    /// The hop grows the plate about its own centre and never moves it: it has
    /// to stay lined up with the bytes it highlights, so it expands evenly in
    /// every direction. What says "higher" is the shadow, not a jump upwards.
    func testTheHopGrowsThePlateWithoutMovingIt() throws {
        var bytes = [UInt8](repeating: 0x11, count: 48)
        bytes.replaceSubrange(18..<20, with: [0xAA, 0xBB])
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        try search("AA BB", in: controller, window)

        let layout = view.hexLayout
        let plate = layout.hexByteFrame(row: 1, column: 2)
            .union(layout.hexByteFrame(row: 1, column: 3))

        /// The yellow's own extent in a column of pixels through the plate.
        func yellowBand(atPhase phase: CGFloat) throws -> (top: CGFloat, bottom: CGFloat) {
            view.indicatorBouncePhaseForTests = phase
            view.needsDisplay = true
            let rep = try render(view)
            view.indicatorBouncePhaseForTests = nil
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let x = Int(plate.midX * scale)
            var first = CGFloat.greatestFiniteMagnitude
            var last = -CGFloat.greatestFiniteMagnitude
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Yellow: red and green up, blue down.
                guard c.redComponent > 0.8, c.greenComponent > 0.8, c.blueComponent < 0.4
                else { continue }
                first = min(first, CGFloat(y) / scale)
                last = max(last, CGFloat(y) / scale)
            }
            return (first, last)
        }

        let rest = try yellowBand(atPhase: 1)
        let top = try yellowBand(atPhase: 0.31)
        XCTAssertGreaterThan(top.bottom - top.top, rest.bottom - rest.top,
                             "the plate is taller at the top of the hop")
        XCTAssertEqual((top.top + top.bottom) / 2, (rest.top + rest.bottom) / 2, accuracy: 0.6,
                       "and its centre has not moved off the row")
        XCTAssertLessThan(top.top, rest.top, "it grew upward")
        XCTAssertGreaterThan(top.bottom, rest.bottom, "and downward by as much")
    }

    /// The hop is slow enough to be seen: a quarter of a second read as a
    /// redraw glitch rather than as movement.
    func testTheHopIsSlowEnoughToRead() {
        XCTAssertGreaterThanOrEqual(HexView.indicatorBounceDuration, 0.5)
    }

    /// Every step pops the indicator — including a wrap onto a lone match,
    /// where no index changes and the press would otherwise look swallowed.
    func testEveryStepPopsTheIndicator() throws {
        let bytes: [UInt8] = [0x11, 0xAA, 0xBB, 0x11]
        let (controller, window) = try makeController(bytes)
        let view = try hexView(window)
        try search("AA BB", in: controller, window)
        XCTAssertTrue(view.isBouncingFindIndicatorForTests, "the search's own landing pops")

        XCTAssertTrue(pumpUntil(2) { !view.isBouncingFindIndicatorForTests },
                      "and the bounce ends on its own")

        let bar = try descendant(FindBarView.self, of: window.contentView!)
        bar.pressFindForTests(.forward)
        XCTAssertTrue(view.isBouncingFindIndicatorForTests,
                      "a wrap onto the only match pops too")
    }

    /// Ink over the yellow is forced black — Apple's own instruction for
    /// `findHighlightColor`, and in dark mode `labelColor` would be white on
    /// yellow. A modified byte keeps its red: an unsaved edit outranks the
    /// convention, and red on yellow still reads as red.
    func testInkOverTheIndicatorIsBlackExceptForAModifiedByte() {
        let view = HexView()
        let layout = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 1)
        var states = [HexByteState](repeating: HexByteState(byte: 0x41), count: 4)
        states[1].isModified = true
        // Bytes 0 and 1 are inside the indicator, 2 and 3 outside it.
        let string = view.hexColumnAttributedString(states: states, layout: layout,
                                                    indicatorColumns: 0..<2)

        func colour(at index: Int) -> NSColor? {
            string.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        }
        // Each byte is two digits plus the grid space after it, so byte n's
        // first digit sits at 3n.
        XCTAssertEqual(colour(at: 0), HexTheme.indicatorInk, "black over the yellow")
        XCTAssertEqual(colour(at: 3), HexTheme.modifiedText,
                       "a modified byte inside the indicator keeps its red")
        XCTAssertEqual(colour(at: 6), HexTheme.byteText,
                       "outside the indicator the ink is the ordinary one")
    }

    /// A fill byte is drawn muted everywhere else (§6) — but not inside the
    /// indicator, where 40 % label on yellow would be a smear.
    func testAFillByteIsNotMutedInsideTheIndicator() {
        let view = HexView()
        let layout = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 1)
        let states = [HexByteState](repeating: HexByteState(byte: 0xFF), count: 2)
        let inside = view.hexColumnAttributedString(states: states, layout: layout,
                                                    indicatorColumns: 0..<1)
        XCTAssertEqual(inside.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       HexTheme.indicatorInk)
        let outside = view.hexColumnAttributedString(states: states, layout: layout)
        XCTAssertEqual(outside.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       HexTheme.mutedByteText)
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
